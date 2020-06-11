require "yaml"
require "json"
require "elasticsearch-crystal/elasticsearch/api"
require "./tools"

# -------------------------------------------------------------------------------------------
# add(documents_path : String, content : Hash, id : String)
#  - add|replace hash content to es document
#  - documents_path index/document( default: #{JOB_INDEX_TYPE} | /#{JOB_INDEX_TYPE}]
# get(documents_path : String, id : String)
#  - get content from es documents_path/id
#
# -------------------------------------------------------------------------------------------
# update(documents_path : String, content : Hash, id : String)
#  - update hash content to es document
#
# -------------------------------------------------------------------------------------------

class Elasticsearch::Client
    class_property :client

    def initialize(hostname : String, port : Int32)
        @client = Elasticsearch::API::Client.new( { :host => hostname, :port => port } )
    end

    def get(documents_path : String, id : String)
        dp = documents_path.split("/")
        response = @client.get(
            {
                :index => dp[dp.size - 2],
                :type => dp[dp.size - 1],
                :id => id
            }
        )
        return response
    end

    def add(documents_path : String, content : Hash, id : String)
        if content["suite"]?
            result_root = "/result/#{content["suite"]}/#{id}"
        else
            result_root = "/result/default/#{id}"
        end
        content = content.merge({"result_root" => result_root, "id" => id})

        dp = documents_path.split("/")
        response = @client.create(
            {
                :index => dp[dp.size - 2],
                :type => dp[dp.size - 1],
                :id => id,
                :body => content
            }
        )
        return response
    end

    def update(documents_path : String, content : Hash)
        dp = documents_path.split("/")
        id = content["id"].to_s
        response = @client.update(
            {
                :index => dp[dp.size - 2],
                :type => dp[dp.size - 1],
                :id => id,
                :body => { :doc => content }
            }
        )
        return response
    end

    # [no use now] add a yaml file to es documents_path
    def add(documents_path : String, fullpath_file : String, id : String)
        yaml = YAML.parse(File.read(fullpath_file))
        return add(documents_path, yaml, id)
    end
end
