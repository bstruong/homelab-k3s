# frozen_string_literal: true

# Standalone snapshot of Alpha's former Engine::Manager tests.
# Run from repo root:
#   ruby -I scripts/alpha-engine scripts/alpha-engine/engine_manager_test.rb

require "minitest/autorun"
require_relative "manager"

class EngineManagerTest < Minitest::Test
  def test_initializes_with_jarvis_defaults
    mgr = Alpha::Engine::Manager.new(base_url: Alpha::Engine::Manager::DEFAULT_BASE_URL)
    assert_equal "jarvis", mgr.namespace
    assert_equal "jarvis", mgr.deployment
    assert_equal "http://127.0.0.1:8080/v1", mgr.base_url
    assert_equal "http://127.0.0.1:8080", mgr.server_root_url
  end

  def test_resolves_presets_correctly
    mgr = Alpha::Engine::Manager.new
    model, al = mgr.resolve_model_and_alias("glm47-reap")
    assert_includes model, "GLM-4.7"
    assert_includes al, "glm47"

    model_q, al_q = mgr.resolve_model_and_alias("qwen36-coder-hybrid")
    assert_includes model_q, "Qwen3.6"
    assert_includes al_q, "qwen36-coder"

    model_38, al_38 = mgr.resolve_model_and_alias("qwen38-27b-ista-2b")
    assert_includes model_38, "IQ2_XS"
    assert_equal "qwen38-27b,qwen38-27b-ista-2b,qwen3.8-27b-ista-2b", al_38

    model_38b, al_38b = mgr.resolve_model_and_alias("qwen38-27b-ista-3b")
    assert_includes model_38b, "IQ3_XXS"
    assert_equal "qwen38-27b-ista-3b,qwen3.8-27b-ista-3b", al_38b

    model_38a, al_38a = mgr.resolve_model_and_alias("qwen38-27b")
    assert_includes model_38a, "IQ2_XS"
    assert_includes al_38a, "qwen38-27b"

    assert_raises(ArgumentError) do
      mgr.resolve_model_and_alias("non-existent-model")
    end
  end

  def test_model_ids_for_returns_openai_model_ids_for_health_matching
    mgr = Alpha::Engine::Manager.new
    assert_includes mgr.model_ids_for("gemma4-4b"), "gemma4-e4b"
    assert_includes mgr.model_ids_for("qwen36-coder-hybrid"), "qwen36-coder-hybrid"
  end

  def test_preset_args_stub_still_exposes_model_path_for_labs
    mgr = Alpha::Engine::Manager.new

    q14 = mgr.preset_args("qwen25-coder-14b")
    assert_includes q14, "/models/qwen2.5-coder-14b-instruct-q4_k_m.gguf"
    assert_includes q14, "--models-preset"

    glm = mgr.preset_args("glm47-reap")
    assert_includes glm, "/models/GLM-4.7-Flash-REAP-23B-A3B-Q4_K_M.gguf"

    q36 = mgr.preset_args("qwen36-coder-hybrid")
    assert_includes q36, "/models/Qwen3.6-35B-A3B-UD-Q4_K_M.gguf"

    gemma = mgr.preset_args("gemma4-4b")
    assert_includes gemma, "/models/gemma-4-e4b-it-q4_k_m.gguf"

    gemma12 = mgr.preset_args("gemma4-12b")
    assert_includes gemma12, "/models/gemma-4-12b-it-q4_k_m.gguf"

    gemma27 = mgr.preset_args("gemma4-27b")
    assert_includes gemma27, "/models/gemma-4-26b-a4b-it-q4_k_m.gguf"

    q38 = mgr.preset_args("qwen38-27b-ista-2b")
    assert_includes q38, "/models/Qwen3.8-27B-GSQ-RCO-IQ2_XS.gguf"
    assert_includes q38, "qwen38-27b,qwen38-27b-ista-2b,qwen3.8-27b-ista-2b"

    q38_3b = mgr.preset_args("qwen38-27b-ista-3b")
    assert_includes q38_3b, "/models/Qwen3.8-27B-GSQ-RCO-IQ3_XXS.gguf"
  end

  def test_patch_preset_refuses_under_jarvis_router_ownership
    mgr = Alpha::Engine::Manager.new
    err = assert_raises(RuntimeError) { mgr.patch_preset!("qwen36-coder-hybrid") }
    assert_match(/JARVIS uses router presets/, err.message)
  end
end
