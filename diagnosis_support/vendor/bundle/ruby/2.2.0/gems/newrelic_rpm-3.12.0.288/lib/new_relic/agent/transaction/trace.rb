# encoding: utf-8
# This file is distributed under New Relic's license terms.
# See https://github.com/newrelic/rpm/blob/master/LICENSE for complete details.

require 'new_relic/agent/transaction/trace_node'

module NewRelic
  module Agent
    class Transaction
      class Trace
        class FinishedTraceError < StandardError; end

        attr_reader :start_time, :root_node
        attr_accessor :transaction_name, :uri, :guid, :xray_session_id,
                      :attributes, :node_count, :finished, :threshold,
                      :profile

        def initialize(start_time)
          @start_time = start_time
          @node_count = 0
          @root_node = NewRelic::Agent::Transaction::TraceNode.new(0.0, "ROOT")
        end

        def sample_id
          self.object_id
        end

        def count_nodes
          self.node_count
        end

        def duration
          self.root_node.duration
        end

        def forced?
          return true if NewRelic::Coerce.int_or_nil(xray_session_id)
          false
        end

        def synthetics_resource_id
          intrinsic_attributes = attributes.intrinsic_attributes_for(NewRelic::Agent::AttributeFilter::DST_TRANSACTION_TRACER)
          intrinsic_attributes[:synthetics_resource_id]
        end

        def to_s_compact
          @root_node.to_s_compact
        end

        def create_node(time_since_start, metric_name = nil)
          raise FinishedTraceError.new "Can't create additional node for finished trace." if self.finished
          self.node_count += 1
          NewRelic::Agent::Transaction::TraceNode.new(time_since_start, metric_name)
        end

        def each_node(&block)
          self.root_node.each_node(&block)
        end

        def prepare_to_send!
          return self if @prepared

          if NewRelic::Agent::Database.should_record_sql?
            collect_explain_plans!
            prepare_sql_for_transmission!
          else
            strip_sql!
          end

          @prepared = true
          self
        end

        def collect_explain_plans!
          return unless NewRelic::Agent::Database.should_collect_explain_plans?
          threshold = NewRelic::Agent.config[:'transaction_tracer.explain_threshold']

          each_node do |node|
            if node[:sql] && node.duration > threshold
              node[:explain_plan] = node.explain_sql
            end
          end
        end

        def prepare_sql_for_transmission!
          strategy = NewRelic::Agent::Database.record_sql_method
          each_node do |node|
            next unless node[:sql]

            case strategy
            when :obfuscated
              node[:sql] = NewRelic::Agent::Database.obfuscate_sql(node[:sql])
            when :raw
              node[:sql] = node[:sql].to_s
            else
              node[:sql] = nil
            end
          end
        end

        def strip_sql!
          each_node do |node|
            node.params.delete(:sql)
          end
        end

        # Iterates recursively over each node in the entire transaction
        # sample tree while keeping track of nested nodes
        def each_node_with_nest_tracking(&block)
          @root_node.each_node_with_nest_tracking(&block)
        end

        def trace_tree
          destination = NewRelic::Agent::AttributeFilter::DST_TRANSACTION_TRACER

          agent_attributes     = self.attributes.agent_attributes_for(destination)
          custom_attributes    = self.attributes.custom_attributes_for(destination)
          intrinsic_attributes = self.attributes.intrinsic_attributes_for(destination)

          [
            NewRelic::Coerce.float(self.start_time),
            {},
            {},
            self.root_node.to_array,
            {
              'agentAttributes' => agent_attributes,
              'userAttributes'  => custom_attributes,
              'intrinsics'      => intrinsic_attributes
            }
          ]
        end

        def to_collector_array(encoder)
          [
            NewRelic::Helper.time_to_millis(self.start_time),
            NewRelic::Helper.time_to_millis(self.root_node.duration),
            NewRelic::Coerce.string(self.transaction_name),
            NewRelic::Coerce.string(self.uri),
            encoder.encode(trace_tree),
            NewRelic::Coerce.string(self.guid),
            nil,
            forced?,
            NewRelic::Coerce.int_or_nil(xray_session_id),
            NewRelic::Coerce.string(self.synthetics_resource_id)
          ]
        end
      end
    end
  end
end
