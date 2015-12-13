#!/usr/bin/env ruby
#
# Sensu Handler: decomm
#
# Modified from https://github.com/agent462/sensu-handler-awsdecomm.
# Uses ridley, aws-sdk v2 and slack for notifications
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# rubocop:disable ClassLength
# rubocop:disable Metrics/AbcSize
# rubocop:disable Metrics/CyclomaticComplexity
# rubocop:disable Metrics/PerceivedComplexity

require 'rubygems' if RUBY_VERSION < '1.9.0'
require 'sensu-handler'
require 'aws-sdk'
require 'ridley'
require 'timeout'
Ridley::Logging.logger.level = Logger.const_get 'ERROR'

# Main decommission class.
class Decomm < Sensu::Handler
  def prefix
    @event['client']['name'] + ' (' + @event['client']['instance_id'] + ') :: '
  end

  def verify_response(response)
    case response
    when Net::HTTPSuccess
      true
    else
      fail response.error!
    end
  end

  def payload(data, color)
    {
      icon_url: 'http://sensuapp.org/img/sensu_logo_large-c92d73db.png',
      attachments: [{
        text: [prefix, data].compact.join(' '),
        color: color
      }]
    }.tap do |payload|
      payload[:channel] = settings['decomm']['slack']['channel']
      payload[:username] = settings['decomm']['slack']['username']
    end
  end

  def slack(msg, color)
    uri = URI(settings['decomm']['slack']['webhook_url'])
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    req = Net::HTTP::Post.new("#{uri.path}?#{uri.query}")
    req.body = payload(msg, color).to_json
    response = http.request(req)
    verify_response(response)
  end

  def delete_sensu_client
    msg = 'Sensu client is being deleted.'
    slack(msg, 'good')
    puts msg
    retries = 3
    begin
      if api_request(:DELETE, '/clients/' + @event['client']['name']).code != '202'
        msg = 'Sensu API call failed.'
        slack(msg, 'danger')
        fail msg
      else
        msg = 'Sensu client deleted successfully.'
        slack(msg, 'good')
      end
    rescue StandardError => e
      if (retries -= 1) >= 0
        sleep 3
        msg = "Deletion failed. Retrying to delete sensu client.\n" + e.message
        slack(msg, 'warning')
        puts msg
        retry
      else
        msg = "Deleting sensu client failed permanently.\n" + e.message
        slack(msg, 'danger')
        raise msg
      end
    end
  end

  def delete_chef_node
    connect_attempts ||= 3
    node_delete_attempts ||= 3
    client_delete_attempts ||= 3

    chef = Ridley.new(
      server_url: 'https://chef.server.url/organizations/cheforg',
      client_name: 'sensu',
      client_key: '/etc/sensu/conf.d/sensu.pem'
      )

    chef_id = chef.search(:node, "ipaddress:#{@settings['client']['address']}")[0].chef_id

    chef_node_exists = chef.node.find(chef_id) ? true : false

    if chef_node_exists
      msg = 'Chef node exists. Will remove it.'
      puts msg
      begin
        chef.node.delete(chef_id)
      rescue => e
        if (node_delete_attempts -= 1) > 0
          msg = 'Unable to delete chef node. Retrying.'
          puts msg
          retry
        else
          msg = "Unable to delete chef node. Giving up.\n" + e.message
          raise msg
        end
      else
        msg = 'Chef node deleted successfully.'
        puts msg
      end
    else
      msg = 'Chef node does not exist.'
      puts msg
    end

    chef_client_exists = chef.client.find(chef_id) ? true : false

    if chef_client_exists
      msg = 'Chef client exists. Will remove it.'
      puts msg
      begin
        chef.client.delete(chef_id)
      rescue => e
        if (client_delete_attempts -= 1) > 0
          msg = 'Unable to delete chef client. Retrying.'
          puts msg
          retry
        else
          msg = "Unable to delete chef client. Giving up.\n" + e.message
          raise msg
        end
      else
        msg = 'Chef client deleted successfully.'
        puts msg
      end
    else
      msg = 'Chef client does not exist.'
      puts msg
    end
  rescue Celluloid::Error
    Celluloid.boot
  rescue Ridley::Errors::ConnectionFailed
    msg = 'Connection failed. Please check chef server connection settings in decomm.json.'
    raise msg
  rescue => e
    retry unless (connect_attempts -= 1).zero?
    msg = 'Unexpected error: ' + e.inspect
    raise msg
  end

  def check_ec2
    instance = false
    ec2 = Aws::EC2::Resource.new(
      region: @settings['decomm']['aws']['region'],
      credentials: Aws::Credentials.new(@settings['decomm']['aws']['access_key'], @settings['decomm']['aws']['secret_key'])
    )
    retries = 3
    begin
      i = ec2.instance(@event['client']['instance_id'])
      if i.exists?
        puts 'Instance exists. Checking state.'
        instance = true
        if i.state.name.to_s =~ /terminated/ || i.state.name.to_s =~ /shutting_down/ || i.state.name.to_s =~ /stopped/
          msg = 'Instance is ' + i.state.name.to_s + '. I will proceed with decommission activities.'
          slack(msg, 'good')
          puts msg
          delete_sensu_client
          delete_chef_node
        else
          msg = 'Client is ' + i.state.name.to_s
          bail(msg)
        end
      end
    rescue Aws::EC2::Errors::ServiceError => e
      if (retries -= 1) >= 0
        sleep 3
        msg = "AWS lookup failed; trying again.\n" + e.message
        slack(msg, 'warning')
        puts msg
        retry
      else
        msg = 'AWS instance lookup failed permanently.'
        slack(msg, 'danger')
        puts msg
        bail(msg)
      end
    end
    return unless instance == false
    puts 'AWS instance not found.'
    delete_sensu_client
    delete_chef_node
  end

  def handle
    check_ec2 if @event['action'].eql?('create')
  end
end
