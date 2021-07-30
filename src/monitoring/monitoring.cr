# SPDX-License-Identifier: MulanPSL-2.0+
# Copyright (c) 2020 Huawei Technologies Co., Ltd. All rights reserved.

require "kemal"
require "json"

require "./filter"
require "./amqp"

module Monitoring
  filter = Filter.instance

  ws "/filter" do |socket|
    query = JSON::Any.new("")

    socket.on_message do |msg|
      # query like {"job_id": "1"}
      # also can be {"job_id": ["1", "2"]}
      query = JSON.parse(msg)
      if query.as_h?
        query = filter.add_filter_rule(query, socket)
      end
    end

    socket.on_close do
      next unless query.as_h?

      filter.remove_filter_rule(query, socket)
    end
  end
end
