# SPDX-License-Identifier: MulanPSL-2.0+
# Copyright (c) 2020 Huawei Technologies Co., Ltd. All rights reserved.
# frozen_string_literal: true

require_relative 'mail_client.rb'
require_relative 'es_query.rb'
require_relative 'constants.rb'
require 'json'

# compose and send email for job result
class MailJobResult
  def initialize(job_id, result_host = SRV_HTTP_HOST, result_port = SRV_HTTP_PORT)
    @job_id = job_id
    @result_host = result_host
    @result_port = result_port
  end

  def send_mail
    json = compose_mail.to_json
    MailClient.new.send_mail(json)
  end

  def compose_mail
    set_submitter_info
    subject = "[Compass-CI] job: #{@job_id} result"
    signature = "Regards\nCompass-CI\nhttps://gitee.com/openeuler/compass-ci"
    body = "Hi,
    Thanks for your participation in Kunpeng and software ecosystem!
    Your Job: #{@job_id} had finished.
    Please check job result: http://#{@result_host}:#{@result_port}#{@result_root}\n\n#{signature}"
    { 'to' => @submitter_email, 'body' => body, 'subject' => subject }
  end

  def set_submitter_info
    job = query_job
    exit unless job && job['email']

    @submitter_email = job['email']
    @result_root = job['result_root']
  end

  def query_job
    es = ESQuery.new
    query_result = es.multi_field_query({ 'id' => @job_id })
    if query_result['hits']['hits'].empty?
      warn "Non-existent job: #{@job_id}"
      return nil
    end

    query_result['hits']['hits'][0]['_source']
  end
end
