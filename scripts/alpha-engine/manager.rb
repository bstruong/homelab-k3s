# frozen_string_literal: true

# Archived from bstruong/alpha (Engine::Manager).
# Ops home: wake / lease JARVIS via kubectl. Alpha gem no longer vendors this.
# Prefer: ./scripts/jarvis-up.sh, ./scripts/jarvis-down.sh, ./scripts/jarvis-lease.sh
# This Ruby client remains for operators who want Manager#up / #acquire_lease! locally.
# Load with: ruby -I scripts/alpha-engine -r ./manager.rb  (or require_relative)
#
require "json"
require "net/http"
require "open3"
require "shellwords"
require "socket"
require "timeout"
require "uri"

module Alpha
  module Engine
    # Thin client for JARVIS (shared k8s inference Deployment (optional)).
    #
    # Production preset SoT is the JARVIS ConfigMap `jarvis-models` / models.ini
    # in homelab-k3s — not this repo's engine/models.ini. Alpha wakes/scales
    # JARVIS, checks health, and optionally holds a lease. Model selection is
    # the OpenAI `model` id on chat completions (router `--models-max 1`).
    #
    #     class Manager
      DEFAULT_HOST = "user@homelab.local"
      DEFAULT_NAMESPACE = "jarvis"
      DEFAULT_DEPLOYMENT = "jarvis"
      DEFAULT_BASE_URL = "http://127.0.0.1:8080/v1"
      DEFAULT_LEASE_CONFIGMAP = "jarvis-lease"

      KNOWN_PRESETS = %w[
        qwen25-coder-14b
        qwen36-coder
        qwen36-coder-hybrid
        glm47-reap
        gemma4-4b
        gemma4-e4b
        gemma4-12b
        gemma4-27b
        qwen38-27b-ista-2b
        qwen38-27b-ista-3b
      ].freeze

      attr_reader :host, :namespace, :deployment, :base_url, :lease_configmap

      def initialize(
        host: ENV.fetch("ALPHA_ENGINE_HOST", DEFAULT_HOST),
        namespace: ENV.fetch("ALPHA_ENGINE_NAMESPACE", DEFAULT_NAMESPACE),
        deployment: ENV.fetch("ALPHA_ENGINE_DEPLOYMENT", DEFAULT_DEPLOYMENT),
        base_url: ENV.fetch("OPENAI_BASE_URL", DEFAULT_BASE_URL),
        lease_configmap: ENV.fetch("JARVIS_LEASE_CONFIGMAP", DEFAULT_LEASE_CONFIGMAP)
      )
        @host = host
        @namespace = namespace
        @deployment = deployment
        @base_url = base_url.chomp("/")
        @lease_configmap = lease_configmap
      end

      def local?
        hostname = Socket.gethostname.downcase
        hostname.include?("watchtower") || host == "localhost" || host == "127.0.0.1"
      end

      def server_root_url
        base_url.sub(%r{/v1\z}, "")
      end

      def healthy?(expected_preset: nil)
        uri = URI.parse("#{server_root_url}/health")
        res = Net::HTTP.start(uri.host, uri.port, open_timeout: 2, read_timeout: 3) do |http|
          http.request(Net::HTTP::Get.new(uri))
        end
        return false unless res.is_a?(Net::HTTPSuccess)

        models_uri = URI.parse("#{base_url}/models")
        res2 = Net::HTTP.start(models_uri.host, models_uri.port, open_timeout: 2, read_timeout: 3) do |http|
          http.request(Net::HTTP::Get.new(models_uri))
        end
        return false unless res2.is_a?(Net::HTTPSuccess)

        if expected_preset
          body = JSON.parse(res2.body) rescue {}
          loaded_ids = Array(body["data"]).flat_map { |m| [ m["id"], *Array(m["aliases"]) ] }.compact
          expected_list = model_ids_for(expected_preset)
          return false unless (loaded_ids & expected_list).any?
        end

        true
      rescue StandardError
        false
      end

      def status
        json_out, err, status = run_cmd("kubectl -n #{namespace} get deployment #{deployment} -o json")
        unless status.success?
          return {
            deployment_found: false,
            error: err.strip,
            running: false,
            healthy: healthy?,
            router_mode: true
          }
        end

        data = JSON.parse(json_out) rescue {}
        spec_replicas = data.dig("spec", "replicas").to_i
        ready_replicas = data.dig("status", "readyReplicas").to_i
        args = data.dig("spec", "template", "spec", "containers", 0, "args") || []
        router_mode = args.include?("--models-preset")

        {
          deployment_found: true,
          deployment: deployment,
          namespace: namespace,
          spec_replicas: spec_replicas,
          ready_replicas: ready_replicas,
          running: ready_replicas.positive?,
          healthy: healthy?,
          router_mode: router_mode,
          active_preset: nil,
          current_args: args
        }
      end

      # Wake JARVIS. Preset is recorded for health checks; the router loads the
      # GGUF when the client sends that model id — we do not patch Deployment args.
      def up(preset: nil, wait: true, timeout: 180)
        current = status
        raise "Deployment #{deployment} not found in namespace #{namespace}: #{current[:error]}" unless current[:deployment_found]

        if preset
          model_ids_for(preset) # validate known id early
        end

        if current[:spec_replicas].zero?
          _out, err, status = run_cmd("kubectl -n #{namespace} scale deployment/#{deployment} --replicas=1")
          raise "Failed to scale deployment #{deployment} to 1: #{err}" unless status.success?
        end

        touch_activity!
        return true unless wait

        wait_until_healthy(timeout: timeout, expected_preset: preset)
      end

      def down
        _out, err, status = run_cmd("kubectl -n #{namespace} scale deployment/#{deployment} --replicas=0")
        raise "Failed to scale deployment #{deployment} to 0: #{err}" unless status.success?

        true
      end

      def ensure_running!(preset: nil, timeout: 180)
        st = status
        if st[:running] && st[:healthy] && (preset.nil? || healthy?(expected_preset: preset))
          touch_activity!
          return true
        end

        up(preset: preset, wait: true, timeout: timeout)
      end

      def acquire_lease!(holder:, ttl_minutes: 60)
        raise ArgumentError, "holder required" if holder.to_s.strip.empty?

        expires = (Time.now.utc + ttl_minutes.to_i * 60).strftime("%Y-%m-%dT%H:%M:%SZ")
        now = Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ")
        annotate = [
          "jarvis.watchtower/holder=#{holder}",
          "jarvis.watchtower/expires-at=#{expires}",
          "jarvis.watchtower/last-activity-at=#{now}"
        ].map { |a| Shellwords.escape(a) }.join(" ")

        _out, err, status = run_cmd(
          "kubectl -n #{namespace} annotate configmap #{lease_configmap} #{annotate} --overwrite"
        )
        raise "Failed to acquire JARVIS lease: #{err}" unless status.success?

        true
      end

      def release_lease!
        now = Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ")
        _out, err, status = run_cmd(
          "kubectl -n #{namespace} annotate configmap #{lease_configmap} " \
          "jarvis.watchtower/holder- jarvis.watchtower/expires-at- " \
          "jarvis.watchtower/last-activity-at=#{Shellwords.escape(now)} --overwrite"
        )
        raise "Failed to release JARVIS lease: #{err}" unless status.success?

        true
      end

      # Client-side mirror of JARVIS preset ids for health matching. Production
      # flags live in homelab-k3s ConfigMap jarvis-models — do not use this to
      # patch the Deployment.
      def model_ids_for(preset_name)
        case preset_name.to_s
        when "qwen25-coder-14b", "qwen25-14b", "14b"
          %w[qwen25-coder-14b qwen2.5-coder-14b]
        when "qwen36-coder"
          %w[qwen36-coder]
        when "qwen36-coder-hybrid", "qwen"
          %w[qwen36-coder-hybrid qwen36-coder]
        when "glm47-reap", "glm47"
          %w[glm47-reap glm-4.7-flash]
        when "gemma4-4b", "gemma-4-e4b", "gemma4:4b", "gemma4", "gemma", "gemma4-e4b"
          %w[gemma4-4b gemma4-e4b gemma-4-e4b gemma-4-4b]
        when "gemma4-12b", "gemma-4-12b", "gemma4:12b", "gemma-12b"
          %w[gemma4-12b gemma-4-12b gemma-12b]
        when "gemma4-27b", "gemma-4-27b", "gemma4:27b", "gemma-27b", "gemma-4-26b-a4b", "gemma4-26b"
          %w[gemma4-27b gemma-4-27b gemma-4-26b-a4b gemma4-26b]
        when "qwen38-27b-ista-2b", "qwen38-27b"
          %w[qwen38-27b qwen38-27b-ista-2b qwen3.8-27b-ista-2b]
        when "qwen38-27b-ista-3b"
          %w[qwen38-27b-ista-3b qwen3.8-27b-ista-3b]
        else
          raise ArgumentError,
            "Unknown preset #{preset_name.inspect}; known client ids: #{KNOWN_PRESETS.join(', ')} " \
            "(JARVIS ConfigMap is SoT — add new ids there first)"
        end
      end

      # @deprecated Prefer model_ids_for. Kept for tests / local single-model labs.
      def resolve_model_and_alias(preset_name)
        ids = model_ids_for(preset_name)
        path = case preset_name.to_s
        when "qwen25-coder-14b", "qwen25-14b", "14b"
          "/models/qwen2.5-coder-14b-instruct-q4_k_m.gguf"
        when "glm47-reap", "glm47"
          "/models/GLM-4.7-Flash-REAP-23B-A3B-Q4_K_M.gguf"
        when "qwen36-coder-hybrid", "qwen36-coder", "qwen"
          "/models/Qwen3.6-35B-A3B-UD-Q4_K_M.gguf"
        when "gemma4-4b", "gemma-4-e4b", "gemma4:4b", "gemma4", "gemma", "gemma4-e4b"
          "/models/gemma-4-e4b-it-q4_k_m.gguf"
        when "gemma4-12b", "gemma-4-12b", "gemma4:12b", "gemma-12b"
          "/models/gemma-4-12b-it-q4_k_m.gguf"
        when "gemma4-27b", "gemma-4-27b", "gemma4:27b", "gemma-27b", "gemma-4-26b-a4b", "gemma4-26b"
          "/models/gemma-4-26b-a4b-it-q4_k_m.gguf"
        when "qwen38-27b-ista-2b", "qwen38-27b"
          "/models/Qwen3.8-27B-GSQ-RCO-IQ2_XS.gguf"
        when "qwen38-27b-ista-3b"
          "/models/Qwen3.8-27B-GSQ-RCO-IQ3_XXS.gguf"
        end
        [ path, ids.join(",") ]
      end

      # @deprecated Under JARVIS, Deployment args are not patched. Returns a
      # descriptive stub for labs/tests; prefer model_ids_for + chat `model` id.
      def preset_args(preset_name)
        model_path, aliases = resolve_model_and_alias(preset_name)
        [
          "--models-preset", "/etc/llama/models.ini",
          "--models-max", "1",
          "--model", model_path,
          "--alias", aliases
        ]
      end

      def patch_preset!(_preset_name)
        raise "JARVIS uses router presets (ConfigMap jarvis-models); " \
              "refusing to patch Deployment #{deployment} args. " \
              "Send model id on /v1/chat/completions instead."
      end

      private
        def run_cmd(cmd)
          full_cmd = if local?
            cmd
          else
            "ssh -o BatchMode=yes -o ConnectTimeout=5 #{host} #{Shellwords.escape(cmd)}"
          end
          Open3.capture3(full_cmd)
        end

        def touch_activity!
          now = Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ")
          run_cmd(
            "kubectl -n #{namespace} annotate configmap #{lease_configmap} " \
            "jarvis.watchtower/last-activity-at=#{Shellwords.escape(now)} --overwrite"
          )
        rescue StandardError
          # Lease ConfigMap may be absent in local docker labs.
          nil
        end

        def wait_until_healthy(timeout: 180, expected_preset: nil)
          deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
          while Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
            return true if healthy?(expected_preset: expected_preset)

            sleep 1
          end
          raise Timeout::Error, "JARVIS at #{base_url} did not become healthy within #{timeout}s"
        end
    end
  end
end
