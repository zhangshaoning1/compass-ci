# SPDX-License-Identifier: MulanPSL-2.0+
# Copyright (c) 2020 Huawei Technologies Co., Ltd. All rights reserved.

class Sched
  def find_job_boot
    value = @env.params.url["value"]
    boot_type = @env.params.url["boot_type"]

    case boot_type
    when "ipxe", "libvirt"
      host = @redis.hash_get("sched/mac2host", normalize_mac(value))
    when "grub"
      host = @redis.hash_get("sched/mac2host", normalize_mac(value))
      submit_host_info_job(value) unless host
    when "container"
      host = value
    end

    response = get_job_boot(host, boot_type)
    job_id = response[/tmpfs\/(.*)\/job\.cgz/, 1]?
    @log.info(%({"job_id": "#{job_id}", "job_state": "boot"})) if job_id

    response
  rescue e
    @log.warn(e)
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
      default_queues << item.strip
    end

    sub_queues = [] of String
    default_queues.each do |queue|
      # TODO: this could be high cost and should be improved in future : keys(pattern).
      matched_queues = @redis.keys("#{QUEUE_NAME_BASE}/sched/#{queue}/*/ready")
      next if matched_queues.empty?

      matched_queues.each do |mq|
        match_data = "#{mq}".match(%r(^#{QUEUE_NAME_BASE}/sched/(#{queue}/.+)/ready$))
        sub_queues << match_data[1] if match_data
      end
    end

    idle_queues = [] of String
    delimiter_queues = [] of String
    default_queues.each do |queue|
      idle_queues << "#{queue}/idle"
      delimiter_queues << "#{queue}/delimiter@localhost"
    end

    all_queues = delimiter_queues + rand_queues(sub_queues) + idle_queues

    return all_queues.uniq
  end

  def get_job_from_queues(queues, testbox)
    job = nil

    queues.each do |queue|
      job = prepare_job("sched/#{queue}", testbox)
      return job if job
    end

    return job
  end

  def get_job_boot(host, boot_type)
    queues = get_queues(host)
    job = get_job_from_queues(queues, host)
    set_lifecycle(job, host)

    if job
      @es.set_job_content(job)
      create_job_cpio(job.dump_to_json_any, Kemal.config.public_folder)
    else
      # for physical machines
      spawn { auto_submit_idle_job(host) }
    end

    return boot_content(job, boot_type)
  end

  private def ipxe_msg(msg)
    "#!ipxe
        echo ...
        echo #{msg}
        echo ...
        reboot"
  end

  private def grub_msg(msg)
    "#!grub
        echo ...
        echo #{msg}
        echo ...
        reboot"
  end

  private def get_boot_container(job : Job)
    response = Hash(String, String).new
    response["docker_image"] = "#{job.docker_image}"
    response["lkp"] = "http://#{INITRD_HTTP_HOST}:#{INITRD_HTTP_PORT}" +
                      JobHelper.service_path("#{SRV_INITRD}/lkp/#{job.lkp_initrd_user}/lkp-#{job.arch}.cgz")
    response["job"] = "http://#{SCHED_HOST}:#{SCHED_PORT}/job_initrd_tmpfs/#{job.id}/job.cgz"

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
    return job["ipxe_response"] if job["suite"] == "install-iso" && job.has_key?("ipxe_response")

    response = "#!ipxe\n\n"

    _initrds_uri = Array(String).from_json(job.initrds_uri).map { |uri| "initrd #{uri}" }
    response += _initrds_uri.join("\n") + "\n"

    _kernel_params = ["kernel #{job.kernel_uri}"] + Array(String).from_json(job.kernel_params) + Array(String).from_json(job.ipxe_kernel_params)
    response += _kernel_params.join(" ")

    response += "\nboot\n"

    return response
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
      return job ? get_boot_ipxe(job) : ipxe_msg("No job now")
    when "grub"
      return job ? get_boot_grub(job) : grub_msg("No job now")
    when "container"
      return job ? get_boot_container(job) : Hash(String, String).new.to_json
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
    fields = ["testbox=#{testbox}", "subqueue=idle"]

    Jobfile::Operate.auto_submit_job(full_path_patterns, fields) if Dir.glob(full_path_patterns).size > 0
  end
end
