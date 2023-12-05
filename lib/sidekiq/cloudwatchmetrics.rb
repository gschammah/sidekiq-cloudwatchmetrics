# frozen_string_literal: true

require "sidekiq"
require "sidekiq/api"

require "aws-sdk-cloudwatch"

module Sidekiq::CloudWatchMetrics
  def self.enable!(**kwargs)
    Sidekiq.configure_server do |config|
      publisher = Publisher.new(**kwargs)

      # Sidekiq enterprise has a globally unique leader thread, making it
      # easier to publish the cluster-wide metrics from one place.
      if defined?(Sidekiq::Enterprise)
        config.on(:leader) do
          publisher.start
        end
      else
        # Otherwise pubishing from every node doesn't hurt, it's just wasteful
        config.on(:startup) do
          publisher.start
        end
      end

      config.on(:quiet) do
        publisher.quiet if publisher.running?
      end

      config.on(:shutdown) do
        publisher.stop if publisher.running?
      end
    end
  end

  class Publisher
    begin
      require "sidekiq/util"
      include Sidekiq::Util
    rescue LoadError
      # Sidekiq 6.5 refactored to use Sidekiq::Component
      require "sidekiq/component"
      include Sidekiq::Component
    end

    INTERVAL = 60 # seconds

    def initialize(config: Sidekiq, client: Aws::CloudWatch::Client.new, namespace: "Sidekiq", process_metrics: false, additional_dimensions: {})
      # Sidekiq 6.5+ requires @config, which defaults to the top-level
      # `Sidekiq` module, but can be overridden when running multiple Sidekiqs.
      @config = config
      @client = client
      @namespace = namespace
      @process_metrics = process_metrics
      @additional_dimensions = additional_dimensions.map { |k, v| {name: k.to_s, value: v.to_s} }
    end

    def start
      logger.info { "Starting Sidekiq CloudWatch Metrics Publisher" }

      @done = false
      @thread = safe_thread("cloudwatch metrics publisher", &method(:run))
    end

    def running?
      !@thread.nil? && @thread.alive?
    end

    def run
      logger.info { "Started Sidekiq CloudWatch Metrics Publisher" }

      # Publish stats every INTERVAL seconds, sleeping as required between runs
      now = Time.now.to_f
      tick = now
      until @stop
        already_published = @config.redis { |redis| redis.get("cloudwatch_metrics:fresh") }

        if already_published
          logger.info { "No Sidekiq CloudWatch Metrics to publish" }
        else
          logger.info { "Publishing Sidekiq CloudWatch Metrics" }
          @config.redis { |redis| redis.set("cloudwatch_metrics:fresh", 1, ex: INTERVAL - 5) }
          publish
        end

        now = Time.now.to_f
        tick = [tick + INTERVAL / 6, now].max
        sleep(tick - now) if tick > now
      end

      logger.info { "Stopped Sidekiq CloudWatch Metrics Publisher" }
    end

    def publish
      now = Time.now
      stats = Sidekiq::Stats.new
      processes = Sidekiq::ProcessSet.new.to_enum(:each).to_a
      workers = Sidekiq::Workers.new.map { |_a, _b, c| c }.group_by { |w| w["queue"] }
      queues = stats.queues

      metrics = [
        {
          metric_name: "ProcessedJobs",
          timestamp: now,
          value: stats.processed,
          unit: "Count",
        },
        {
          metric_name: "FailedJobs",
          timestamp: now,
          value: stats.failed,
          unit: "Count",
        },
        {
          metric_name: "EnqueuedJobs",
          timestamp: now,
          value: stats.enqueued,
          unit: "Count",
        },
        {
          metric_name: "DefaultQueueLatency",
          timestamp: now,
          value: stats.default_queue_latency,
          unit: "Seconds",
        }
      ]

      # utilization = calculate_utilization(processes) * 100.0

      # unless utilization.nan?
      #   metrics << {
      #     metric_name: "Utilization",
      #     timestamp: now,
      #     value: utilization,
      #     unit: "Percent",
      #   }
      # end

      # processes.group_by do |process|
      #   process["tag"]
      # end.each do |(tag, tag_processes)|
      #   next if tag.nil?

      #   tag_utilization = calculate_utilization(tag_processes) * 100.0

      #   unless tag_utilization.nan?
      #     metrics << {
      #       metric_name: "Utilization",
      #       dimensions: [{name: "Tag", value: tag}],
      #       timestamp: now,
      #       value: tag_utilization,
      #       unit: "Percent",
      #     }
      #   end
      # end

      if @process_metrics
        processes.each do |process|
          process_utilization = process["busy"] / process["concurrency"].to_f * 100.0

          unless process_utilization.nan?
            process_dimensions = [{name: "Hostname", value: process["hostname"]}]

            if process["tag"]
              process_dimensions << {name: "Tag", value: process["tag"]}
            end

            metrics << {
              metric_name: "Utilization",
              dimensions: process_dimensions,
              timestamp: now,
              value: process_utilization,
              unit: "Percent",
            }
          end
        end
      end

      queues.each do |(queue_name, queue_size)|
        next if queue_name =~ /sidekiq-alive/

        busy_size = workers[queue_name]&.size || 0

        metrics << {
          metric_name: "QueueSize",
          dimensions: [{name: "QueueName", value: queue_name}],
          timestamp: now,
          value: queue_size + busy_size,
          unit: "Count",
        }

        queue_latency = Sidekiq::Queue.new(queue_name).latency

        metrics << {
          metric_name: "QueueLatency",
          dimensions: [{name: "QueueName", value: queue_name}],
          timestamp: now,
          value: queue_latency,
          unit: "Seconds",
        }
      end

      unless @additional_dimensions.empty?
        metrics = metrics.each do |metric|
          metric[:dimensions] = (metric[:dimensions] || []) + @additional_dimensions
        end
      end

      # We can only put 20 metrics at a time
      metrics.each_slice(20) do |some_metrics|
        @client.put_metric_data(
          namespace: @namespace,
          metric_data: some_metrics,
        )
      end
    end

    # Returns the total number of workers across all processes
    private def calculate_capacity(processes)
      processes.map do |process|
        process["concurrency"]
      end.sum
    end

    # Returns busy / concurrency averaged across processes (for scaling)
    # Avoid considering processes not yet running any threads
    private def calculate_utilization(processes)
      process_utilizations = processes.map do |process|
        process["busy"] / process["concurrency"].to_f
      end.reject(&:nan?)

      process_utilizations.sum / process_utilizations.size.to_f
    end

    def quiet
      logger.info { "Quieting Sidekiq CloudWatch Metrics Publisher" }
      @stop = true
    end

    def stop
      logger.info { "Stopping Sidekiq CloudWatch Metrics Publisher" }
      @stop = true
      @thread.wakeup
      @thread.join
    rescue ThreadError
      # Don't raise if thread is already dead.
      nil
    end
  end
end
