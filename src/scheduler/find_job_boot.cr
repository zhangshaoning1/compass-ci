# SPDX-License-Identifier: MulanPSL-2.0+
# Copyright (c) 2020 Huawei Technologies Co., Ltd. All rights reserved.

class Sched
  def find_job_boot
    @env.set "job_stage", "boot"

    if @env.get?("ws")
      send_timeout_signal
      value = @env.ws_route_lookup.params["value"]
      boot_type = @env.ws_route_lookup.params["boot_type"]
    else
      value = @env.params.url["value"]
      boot_type = @env.params.url["boot_type"]
    end

    case boot_type
    when "ipxe", "libvirt"
      mac = normalize_mac(value)
      host = @redis.hash_get("sched/mac2host", mac)
      host = handle_new_hw(mac) unless host
    when "grub"
      host = @redis.hash_get("sched/mac2host", normalize_mac(value))
      submit_host_info_job(value) unless host
    when "container"
      host = value
    end

    @env.set "testbox", host
    response = get_job_boot(host, boot_type)
    job_id = response[/tmpfs\/(.*)\/job\.cgz/, 1]?
    @env.set "job_id", job_id

    if @env.get?("ws")
      @env.socket.send({
        "type" => "boot",
        "response" => response
      }.to_json) unless @env.get?("ws_state") == "close"
    else
      response
    end
  rescue e
    @env.response.status_code = 500
    @log.warn({
      "message" => e.to_s,
      "error_message" => e.inspect_with_backtrace.to_s
    }.to_json)
  ensure
    if @env.get?("ws")
      @env.socket.close
      @env.channel.close
    end
    send_mq_msg
  end

  def handle_new_hw(mac)
    host = "sched-#{LAB}-#{mac}"
    queues = host
    @redis.hash_set("sched/mac2host", normalize_mac(mac), host)
    @redis.hash_set("sched/host2queues", host, queues)
    Jobfile::Operate.auto_submit_job(
      "#{ENV["LKP_SRC"]}/jobs/host-info.yaml", ["testbox=unknown", "queue=#{host}", "is_store=yes"])
    return host
  end

  def send_timeout_signal
    spawn do
      900.times do
        sleep 2
        break if @env.channel.closed?
      end

      @env.channel.send({"type" => "timeout"}) unless @env.channel.closed?
    end
  end

  # auto submit a job to collect the host information.
  #
  # grub hostname is joined with ":", like "00:01:02:03:04:05".
  # remind: if joined with "-", last "-05" is treated as host number
  #         then hostname will be "sut-00-01-02-03-04" !!!
  def submit_host_info_job(mac)
    host = "sut-#{mac}"
    @redis.hash_set("sched/mac2host", normalize_mac(mac), host)

    Jobfile::Operate.auto_submit_job(
      "#{ENV["LKP_SRC"]}/jobs/host-info.yaml",
      ["testbox=#{host}"])
  end

  def rand_queues(queues)
    return queues if queues.empty?

    queues_size = queues.size
    base = Random.rand(queues_size)
    temp_queues = [] of String

    (0..queues_size - 1).each do |index|
      temp_queues << queues[(index + base) % queues_size]
    end

    return temp_queues
  end

  def get_queues(host)
    queues_str = @redis.hash_get("sched/host2queues", host)
    return [] of String unless queues_str

    default_queues = [] of String
    queues_str.split(',', remove_empty: true) do |item|
      default_queues << "sched/ready/#{item.strip}/"
    end

    return default_queues.uniq
  end

  def get_job_from_queues(queues, testbox)
    job = nil
    etcd_job = consume_job(queues, testbox)
    return nil unless etcd_job

    job_id = etcd_job.key.split("/")[-1]
    if job_id
      begin
        job = @es.get_job(job_id.to_s)
        @log.warn("job_is_nil, job id=#{job_id.to_s}") unless job
      rescue ex
        @log.warn("Invalid job (id=#{job_id}) in es. Info: #{ex}")
        @log.warn(ex.inspect_with_backtrace)
      end
    end

    if job
      @log.info("#{testbox} got the job #{job_id}")
      job.update({"testbox" => testbox})
      update_kernel_params(job)
      job.set_result_root
      job.set_time("boot_time")
      @log.info(%({"job_id": "#{job_id}", "result_root": "/srv#{job.result_root}", "job_state"
: "set result root"}))
      set_id2job(job)
    end

    return job
  end

  def update_kernel_params(job)
    host_info = Utils.get_host_info(job.testbox)
    job.set_rootfs_disk(get_rootfs_disk(host_info)) unless job.has_key?("rootfs_disk")
    job.set_crashkernel(get_crashkernel(host_info))
  end

  def consume_job(queues, testbox)
    job, revision = consume_by_list(queues)
    return job if job

    spawn auto_submit_idle_job(testbox)

    if @env.get?("ws")
      return if ["timeout", "close"].includes?(@env.get?("ws_state"))

      interact_with_client("release_memory") if @env.get?("client_memory") == "request"

      return if ["timeout", "close"].includes?(@env.get?("ws_state"))

      @env.set "client_memory", "release"
    end

    consume_by_watch(queues, revision)
  end

  def interact_with_client(type)
    @env.socket.send({"type" => type}.to_json)
    while true
      Fiber.yield
      msg = @env.channel.receive
      return true if msg["type"]? == type
      next unless msg["type"]? == "timeout"

      @env.set "ws_state", "timeout"
      return
    end
  rescue
    return
  end

  def consume_by_list(queues)
    loop do
      jobs, revision = get_history_jobs(queues)
      email_jobs = split_jobs_by_email(jobs)
      return nil, revision if email_jobs.empty?

      # connection mode is websocket
      # the client has not been instructed to apply for memory
      if @env.get?("ws") && @env.get?("client_memory") != "request"
        res = interact_with_client("request_memory")
        return nil, revision unless res

        @env.set "client_memory", "request"
      end

      loop do
        job = pop_job_by_priority(email_jobs)
        return nil, revision unless job

        return job, revision if ready2process(job)
      end
    end
  end

  def split_jobs_by_email(jobs)
    hash = Hash(String, Array(Etcd::Model::Kv)).new
    jobs.each do |job|
      key = job.key.split("/")[5]
      if hash.has_key?(key)
        hash[key] << job
      else
        hash[key] = [job]
      end
    end

    return hash
  end

  def pop_job_by_priority(email_jobs)
    delimiter = "delimiter@localhost"
    if email_jobs.has_key?(delimiter)
      return email_jobs[delimiter].delete_at(0) unless email_jobs[delimiter].empty?

      email_jobs.delete(delimiter)
    end

    keys = rand_queues(email_jobs.keys)
    keys.each do |key|
      return email_jobs[key].delete_at(0) unless email_jobs[key].empty?

      email_jobs.delete(key)
    end
  end

  def get_history_jobs(queues)
    revisions = [] of Int64
    ec = EtcdClient.new
    jobs = [] of Etcd::Model::Kv
    queues.each do |queue|
      job = ec.range_prefix(queue, ETCD_RANGE_SIZE)
      revisions << job.header.not_nil!.revision
      jobs += job.kvs
    end

    ec.close

    return jobs, revisions.min
  end

  def consume_by_watch(queues, revision)
    ready_queues = split_ready_queues(queues)

    close_consume()

    ech = Hash(EtcdClient, Etcd::Watch::Watcher).new
    ready_queues.each do |queue|
      ec = EtcdClient.new
      watcher = ec.watch_prefix(queue, start_revision: revision.to_i64, progress_notify: false, filters: [Etcd::Watch::Filter::NODELETE]) do |events|
        @env.watch_channel.send(events) unless @env.watch_channel.closed?
      end
      ech[ec] = watcher
    end

    watchers = start_watcher(ech)
    loop_handle_event(ech)
  end

  def close_consume()
    spawn {
      900.times do
        sleep 2
        break if @env.watch_channel.closed?
      end

      @env.watch_channel.send("close") unless @env.watch_channel.closed?
    }
  end

  def split_ready_queues(queues)
    ready_queues = [] of String
    queues.each do |queue|
      tmp = queue.split("/")
      # sched/vm-test/ready/
      # sched/ready/vm-test/
      ready_queues << "#{tmp[0, 3].join("/")}/"
    end

    ready_queues.uniq
  end

  def start_watcher(ech)
    ech.each do |ec, watcher|
      spawn { watcher.start }
      Fiber.yield
    end
  end

  def loop_handle_event(ech)
    @env.set "watch_state", "watching"
    while true
      events = @env.watch_channel.receive
      return if events.is_a?(String)

      if @env.get?("ws")
        return unless interact_with_client("request_memory")
      end

      events.each do |event|
        return event.kv if ready2process(event.kv)
      end

      if @env.get?("ws")
        return unless interact_with_client("release_memory")
      end
    end
  ensure
     close_watch(ech)
  end

  def close_watch(ech)
    @env.set "watch_state", "finished"
    ech.each do |ec, watcher|
      watcher.stop
      ec.close
    end

    @env.watch_channel.close
  end

  def ready2process(job)
    ec = EtcdClient.new
    # /queues/sched/vm-test/ready/caoxl78320@163.com/crystal.2627369
    # /queues/sched/ready/vm-test/caoxl78320@163.com/crystal.2627369
    f_queue = job.key
    # ["", "queues", "sched", "vm-test", "ready", "caoxl78320@163.com", "crystal.2627369"]
    # ["", "queues", "sched", "ready", "vm-test", "caoxl78320@163.com", "crystal.2627369"]
    tmp = f_queue.split("/")
    if "ready" == tmp[3]
      t_queue = f_queue.gsub("/ready/", "/in_process/")
    else
      tmp = f_queue.split("/")
      tmp.delete("ready")
      tmp.insert(3, "in_process")
      t_queue = tmp.join("/")
    end
    value = job.value
    res = ec.move(f_queue, t_queue, value)
    ec.close
    return res
  end

  def get_job_boot(host, boot_type)
    queues = get_queues(host)

    raise "Queues are not registered for this testbox: #{host}" if queues.empty?

    # do before get job from etcd
    # because if no job will hang
    # need to update information in a timely manner
    update_testbox_and_job(nil, host, queues)
    @env.set "state", "requesting"
    send_mq_msg

    job = get_job_from_queues(queues, host)
    update_testbox_and_job(job, host, queues) if job

    if job
      job["last_success_stage"] = "boot"
      @es.set_job_content(job)
      @env.set "job_id", job["id"]
      @env.set "deadline", job["deadline"]
      @env.set "job_stage", job["job_stage"]
      @env.set "state", "booting"
      create_job_cpio(job.dump_to_json_any, Kemal.config.public_folder)
    else
      # for physical machines
      spawn { auto_submit_idle_job(host) }
    end

    return boot_content(job, boot_type)
  end

  private def boot_msg(boot_type, msg)
    "#!#{boot_type}
        echo ...
        echo #{msg}
        echo ...
        chain http://#{ENV["SCHED_HOST"]}:#{ENV["SCHED_PORT"]}/boot.ipxe/mac/${mac:hexhyp}"
  end

  private def get_boot_container(job : Job)
    response = Hash(String, String).new
    response["job_id"] = job.id.to_s
    response["docker_image"] = "#{job.docker_image}"
    response["initrds"] = job.get_common_initrds().to_json

    return response.to_json
  end

  private def get_boot_grub(job : Job)
    initrd_lkp_cgz = "lkp-#{job.os_arch}.cgz"

    response = "#!grub\n\n"
    response += "linux (http,#{OS_HTTP_HOST}:#{OS_HTTP_PORT})"
    response += "#{JobHelper.service_path("#{SRV_OS}/#{job.os_dir}/vmlinuz")} user=lkp"
    response += " job=/lkp/scheduled/job.yaml RESULT_ROOT=/result/job"
    response += " rootovl ip=dhcp ro root=#{job.kernel_append_root}\n"

    response += "initrd (http,#{OS_HTTP_HOST}:#{OS_HTTP_PORT})"
    response += JobHelper.service_path("#{SRV_OS}/#{job.os_dir}/initrd.lkp")
    response += " (http,#{INITRD_HTTP_HOST}:#{INITRD_HTTP_PORT})"
    response += JobHelper.service_path("#{SRV_INITRD}/lkp/#{job.lkp_initrd_user}/#{initrd_lkp_cgz}")
    response += " (http,#{SCHED_HOST}:#{SCHED_PORT})/job_initrd_tmpfs/"
    response += "#{job.id}/job.cgz\n"

    response += "boot\n"

    return response
  end


  private def get_boot_ipxe(job : Job)
    return job["custom_ipxe"] if job["suite"].starts_with?("install-iso") && job.has_key?("custom_ipxe")

    response = "#!ipxe\n\n"
    response += "# nr_nic=" + job["nr_nic"] + "\n" if job.has_key?("nr_nic")

    _initrds_uri = Array(String).from_json(job.initrds_uri).map { |uri| "initrd #{uri}" }
    _initrds_uri.insert(1, "initrd #{job.modules_uri}")
    _kernel_initrds = _initrds_uri.map { |initrd| " initrd=#{File.basename(initrd.split("initrd ")[-1])}"}
    response += _initrds_uri.join("\n") + "\n"

    _kernel_params = ["kernel #{job.kernel_uri}"] + Array(String).from_json(job.kernel_params) + _kernel_initrds
    _rootfs_disk = " rootfs_disk=#{JSON.parse(job["rootfs_disk"]).as_a.join(",")}"
    response += _kernel_params.join(" ") + _rootfs_disk + " crashkernel=#{job["crashkernel"]}"

    response += "\nboot\n"

    return response
  end

  private def get_rootfs_disk(host_info)
    rootfs_disk = [] of JSON::Any
    temp = host_info.has_key?("rootfs_disk") ? host_info["rootfs_disk"].as_a : [] of JSON::Any
    temp.each do |item|
      rootfs_disk << JSON::Any.new("#{item}")
    end

    return rootfs_disk
  end

  private def get_memory(host_info)
    if host_info.has_key?("memory")
      return $1 if "#{host_info["memory"]}" =~ /(\d+)g/i
    end
  end

  private def get_crashkernel(host_info)
    memory = get_memory(host_info)
    return "auto" unless memory

    memory = memory.to_i
    if memory <= 8
      return "auto"
    elsif 8 < memory <= 16
      return "256M"
    else
      return "512M"
    end
  end


  private def get_boot_libvirt(job : Job)
    _kernel_params = job["kernel_params"]?
    _kernel_params = _kernel_params.as_a.map(&.to_s).join(" ") if _kernel_params

    _vt = job["vt"]?
    _vt = Hash(String, String).new unless (_vt && _vt != nil)

    return {
      "job_id"             => job.id,
      "kernel_uri"         => job.kernel_uri,
      "initrds_uri"        => job["initrds_uri"]?,
      "kernel_params"      => _kernel_params,
      "result_root"        => job.result_root,
      "LKP_SERVER"         => job["LKP_SERVER"]?,
      "vt"                 => _vt,
      "RESULT_WEBDAV_PORT" => job["RESULT_WEBDAV_PORT"]? || "3080",
      "SRV_HTTP_CCI_HOST"  => SRV_HTTP_CCI_HOST,
      "SRV_HTTP_CCI_PORT"  => SRV_HTTP_CCI_PORT,
    }.to_json
  end

  def set_id2upload_dirs(job)
    @redis.hash_set("sched/id2upload_dirs", job.id, job.upload_dirs)
  end

  def boot_content(job : Job | Nil, boot_type : String)
    set_id2upload_dirs(job) if job

    case boot_type
    when "ipxe"
      return job ? get_boot_ipxe(job) : boot_msg(boot_type, "No job now")
    when "grub"
      return job ? get_boot_grub(job) : boot_msg(boot_type, "No job now")
    when "container"
      return job ? get_boot_container(job) : {"job_id" => "0"}.to_json
    when "libvirt"
      return job ? get_boot_libvirt(job) : {"job_id" => ""}.to_json
    else
      raise "Not defined boot type #{boot_type}"
    end
  end

  private def prepare_job(queue_name, testbox)
    response = @task_queue.consume_task(queue_name)
    job_id = JSON.parse(response[1].to_json)["id"] if response[0] == 200
    job = nil

    if job_id
      begin
        job = @es.get_job(job_id.to_s)
      rescue ex
        @log.warn("Invalid job (id=#{job_id}) in es. Info: #{ex}")
        @log.warn(ex.inspect_with_backtrace)
      end
    end

    if job
      job.update({"testbox" => testbox})
      job.set_result_root
      @log.info(%({"job_id": "#{job_id}", "result_root": "/srv#{job.result_root}", "job_state": "set result root"}))
      @redis.set_job(job)
    end
    return job
  end

  private def auto_submit_idle_job(testbox)
    full_path_patterns = "#{CCI_REPOS}/#{LAB_REPO}/allot/idle/#{testbox}/*.yaml"
    fields = ["testbox=#{testbox}", "subqueue=idle", "--no-pack"]

    Jobfile::Operate.auto_submit_job(full_path_patterns, fields) if Dir.glob(full_path_patterns).size > 0
  end
end
