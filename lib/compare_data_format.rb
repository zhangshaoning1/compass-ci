# SPDX-License-Identifier: MulanPSL-2.0+ or GPL-2.0
# Copyright (c) 2020 Huawei Technologies Co., Ltd. All rights reserved.
# frozen_string_literal: true

require 'terminal-table'

# ----------------------------------------------------------------------------------------------------
# format compare results for a specific format
#
class FormatEchartData
  def initialize(compare_results, template_params, group_params, dims = [], group_testbox)
    @compare_results = compare_results
    @template_params = template_params
    @group_params = group_params
    @dims = dims
    @compare_dims = compare_dims(dims)
    @data_set = {}
    @title = template_params['title'] || nil
    @group_testbox = group_testbox
  end

  def format_for_echart
    echart_result = {}
    echart_result['title'] = @template_params['title']
    echart_result['unit'] = @template_params['unit']
    @x_name = @template_params['x_params']
    echart_result['x_name'] = @x_name.join('|') if @x_name
    echart_result['tables'] = convert_to_echart_dataset

    echart_result
  end

  def convert_to_echart_dataset
    @x_params = sort_x_params(@compare_results.keys)
    @compare_results.each_value do |metrics_values|
      metrics_values.each do |metric, metric_value|
        assign_echart_data_set(metric, metric_value)
      end
    end

    @data_set
  end

  def assign_echart_data_set(metric, metric_value)
    @data_set[metric] = {}
    metric_value.each do |value_type, values| # value_type can be: average, standard_deviation, change
      @data_set[metric][value_type] = {
        'dimensions' => ['dimensions']
      }

      dimension_list = values.keys.sort
      @data_set[metric][value_type]['dimensions'] += dimension_list
      @data_set[metric][value_type]['source'] = assign_echart_source(metric, value_type, dimension_list)
    end
  end

  def assign_echart_source(metric, value_type, dimensions)
    source = []
    source << @x_params.clone
    dimensions.each do |dimension|
      dimension_values = [dimension]
      @x_params.each do |x_param|
        if @compare_results[x_param][metric] && @compare_results[x_param][metric][value_type]
          dimension_values << @compare_results[x_param][metric][value_type][dimension]
        else
          source[0].delete(x_param)
        end
      end
      source << dimension_values
    end

    source
  end

  # -------------------------------------------------------------------------------------------------
  # format data for api
  # output:
  # [
  #   {
  #     "title": "iperf.tcp.sender.bps",
  #     "datas": [
  #       {
  #         "name": "openeuler",
  #         "data": [22690569006.73847, 26416908414.62344, ...]
  #         "deviation": [15.41451513296539, 22.716525982147182, ...],
  #         "x_params": [ "10", "20", ...]
  #       },
  #       {...},
  #     ]
  #   },
  #   ...
  # ]
  # -------------------------------------------------------------------------------------------------
  def format_echart_data(transposed = true)
    # kv[0]: group
    # kv[1]: metrics_vaules
    if transposed
      sort_compare_result(@compare_results).each do |kv|
        kv[1].each do |metric, values|
          @data_set[metric] ||= {}
          @data_set[metric]['title'] = metric
          @data_set[metric]['test_params'] = @group_params
          @data_set[metric]['testbox'] = @group_testbox[@group_params]
          @data_set[metric]['datas'] ||= {}
          assign_transposed_change_datas(kv[0], metric, values)
          assign_transposed_avg_datas(kv[0], metric)
        end
      end
    else
      sort_compare_result(@compare_results).each do |kv|
        group = kv[0]
        @data_set[group] ||= {}
        @data_set[group]['title'] = @title || group
        @data_set[group]['test_params'] = @group_params
        @data_set[group]['testbox'] = @group_testbox[@group_params]
        @data_set[group]['datas'] ||= {}
        kv[1].each do |metric, values|
          assign_change_datas(group, metric)
          assign_avg_datas(group, metric)
        end
      end
    end

    convert_echart_line_data
  end

  def assign_change_datas(group, metric)
    @data_set[group]['datas']['change'] ||= {}
    @compare_dims.each do |dim|
      @data_set[group]['datas']['change'][dim] ||= {}
      @data_set[group]['datas']['change'][dim]['series'] = dim
      @data_set[group]['datas']['change'][dim]['data'] ||= []
      @data_set[group]['datas']['change'][dim]['x_params'] ||= []

      @data_set[group]['datas']['change'][dim]['x_params'] << metric
      @data_set[group]['datas']['change'][dim]['data'] << assign_value(group, metric, 'change', dim)
    end
  end

  def assign_avg_datas(group, metric)
    @data_set[group]['datas']['average'] ||= {}
    @dims.each do |dim|
      @data_set[group]['datas']['average'][dim] ||= {}
      @data_set[group]['datas']['average'][dim]['series'] = dim
      @data_set[group]['datas']['average'][dim]['data'] ||= []
      @data_set[group]['datas']['average'][dim]['deviation'] ||= []
      @data_set[group]['datas']['average'][dim]['x_params'] ||= []

      @data_set[group]['datas']['average'][dim]['x_params'] << metric
      @data_set[group]['datas']['average'][dim]['data'] << assign_value(group, metric, 'average', dim)
      @data_set[group]['datas']['average'][dim]['deviation'] << assign_value(group, metric, 'standard_deviation', dim)
    end
  end

  def assign_transposed_change_datas(x_param, metric, values)
    @data_set[metric]['datas']['change'] ||= {}
    @compare_dims.each do |dim|
      @data_set[metric]['datas']['change'][dim] ||= {}
      @data_set[metric]['datas']['change'][dim]['series'] = dim
      @data_set[metric]['datas']['change'][dim]['data'] ||= []
      @data_set[metric]['datas']['change'][dim]['x_params'] ||= []

      @data_set[metric]['datas']['change'][dim]['x_params'] << x_param
      @data_set[metric]['datas']['change'][dim]['data'] << assign_value(x_param, metric, 'change', dim)
    end
  end

  def assign_transposed_avg_datas(x_param, metric)
    @data_set[metric]['datas']['average'] ||= {}
    @dims.each do |dim|
      @data_set[metric]['datas']['average'][dim] ||= {}
      @data_set[metric]['datas']['average'][dim]['series'] = dim
      @data_set[metric]['datas']['average'][dim]['data'] ||= []
      @data_set[metric]['datas']['average'][dim]['deviation'] ||= []
      @data_set[metric]['datas']['average'][dim]['x_params'] ||= []

      @data_set[metric]['datas']['average'][dim]['x_params'] << x_param
      @data_set[metric]['datas']['average'][dim]['data'] << assign_value(x_param, metric, 'average', dim)
      @data_set[metric]['datas']['average'][dim]['deviation'] << assign_value(x_param, metric, 'standard_deviation', dim)
    end
  end

  def assign_value(x_param, metric, type, dim)
    return 0 unless @compare_results[x_param].key?(metric)
    return 0 unless @compare_results[x_param][metric].key?(type)
    return 0 unless @compare_results[x_param][metric][type].key?(dim)
    return @compare_results[x_param][metric][type][dim]
  end

  def convert_echart_line_data
    echart_data = []
    @data_set.each_value do |metric_values|
      table_datas = {}

      metric_values.each do |key, values|
        if key != 'datas'
          table_datas.merge!({key => values})
          next
        end

        # change data: {"change" => {...}} --> {"change" => []}
        datas = {}
        values.each do |type, data|
          type_data = []
          data.each do |_k, value|
            type_data << value
          end
          datas[type] = type_data
        end
        table_datas['datas'] = datas
      end
      echart_data << table_datas
    end

    echart_data
  end
end

# ----------------------------------------------------------------------------------------------------
# format compare template results into a table format
#
class FormatTableData
  def initialize(result_hash, row_size = 8)
    @title = result_hash['title']
    @tables = result_hash['tables']
    @unit = result_hash['unit']
    @x_name = result_hash['x_name']
    @row_size = row_size
  end

  def show_table
    @tables.each do |table_title, table|
      @tb = Terminal::Table.new
      set_table_title
      row_num = get_row_num(table)
      split_data_column(table_title, table, row_num)
      set_align_column
      print_table
    end
  end

  def set_table_title
    @tb.title = "#{@title} (unit: #{@unit}, x_name: #{@x_name})"
  end

  def get_row_num(table)
    data_column_size = table['average']['source'][0].size
    unless @row_size.positive?
      warn('row size must be positive!')
      exit
    end
    (data_column_size / @row_size.to_f).ceil
  end

  def split_data_column(table_title, table, row_num)
    row_num.times do |row|
      starts = 1 + row * @row_size
      ends = starts + @row_size
      set_field_names(table_title, table, starts, ends)
      add_rows(table, starts, ends)
      break if row == row_num - 1

      @tb.add_separator
      @tb.add_separator
    end
  end

  def set_field_names(table_title, table, starts, ends)
    field_names = [table_title]
    field_names.concat(table['average']['source'][0][starts - 1...ends - 1])
    @tb.add_row(field_names)
    @tb.add_separator
  end

  def add_rows(table, starts, ends)
    row_names = %w[average standard_deviation change]
    max_size = row_names.map(&:size).max
    row_names.each do |row_name|
      next unless table[row_name]

      dimensions_size = table[row_name]['dimensions'].size
      (1...dimensions_size).each do |index|
        add_row(table, row_name, index, max_size, starts, ends)
      end
    end
  end

  def add_row(table, row_name, index, max_size, starts, ends)
    row = table[row_name]['source'][index]
    row_title = [row_name + ' ' * (max_size - row_name.size), row[0]].join(' ')
    format_data_row = row[starts...ends]
    if row_name == 'change'
      format_data_row.map! { |data| format('%.1f%%', data) }
    else
      format_data_row.map! { |data| format('%.2f', data) }
    end
    @tb.add_row([row_title, *format_data_row])
  end

  def set_align_column
    @tb.number_of_columns.times do |index|
      @tb.align_column(index + 1, :right)
    end
    @tb.align_column(0, :left)
  end

  def print_table
    puts @tb
    puts
  end
end

# input: x_params_list
# eg: ["1G|4K", "1G|1024k", "1G|128k", 2G|4k]
# output:
# ["1G|4K", "1G|128k", "1G|1024k", "2G|4k"]
def sort_x_params(x_params_list)
  x_params_hash = {}
  x_params_list.each do |param|
    params = param.gsub(/[a-zA-Z]+$/, '').split('|').map(&:to_i)
    x_params_hash[params] = param
  end

  x_params_hash.sort.map { |h| h[1] }
end

def numeric?(item)
  Float(item)
rescue
  nil
end

def score(item)
  score = 0
  return item.to_f*0.1 if numeric?(item)
  return 1000 if item == 'System_Benchmarks_Index_Score'

  items = item.split('|')
  mutil = 1
  items.each do |i|
    v = i.sub(/[a-zA-Z]+/, '')
    if v.empty?
      return 0
    else
      if numeric?(v)
        score += v.to_f * mutil
      else
        return 0
      end
    end
    mutil *= 10
  end

  score
end

# sort Hash(compare_result) by key
# input like:
# {
#   "1G|4K" => {...},
#   "1G|1024k" => {...},
#   "1G|128k" => {...},
#   "2G|4k" => {...}
# }
# output:
# [
#  ["1G|4K", {...}],
#  ["1G|128k", {...}],
#  ["1G|1024k", {...}],
#  ["2G|4k", {...}]
# ]
def sort_compare_result(compare_result)
  compare_result.sort{|a, b| score(a[0]) <=> score(b[0])}
end

# input eg:
#   ["openeuler", "centos", "debian"]
# return eg:
#   ["centos vs openeuler", "debian vs openeuler"]
def compare_dims(dims)
  compare_dims = []
  (1...dims.size).each do |i|
    compare_dims << dims[i] + ' vs ' + dims[0]
  end

  compare_dims
end
