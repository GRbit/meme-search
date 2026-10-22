# frozen_string_literal: true

require "test_helper"

class Settings::ImageToTextsControllerTest < ActionDispatch::IntegrationTest
  test "index renders provider tabs and local models" do
    get settings_image_to_texts_path

    assert_response :success
    assert_select "h1", "AI Models"
    assert_select "button", text: "Local generator"
    assert_select "button", text: "OpenAI-compatible API"
    assert_select "#image_to_texts"
  end

  test "index opens the tab of the provider set by the environment" do
    with_openai_env_cleared do
      with_env("IMAGE_DESCRIPTION_PROVIDER" => "openai") do
        get settings_image_to_texts_path
      end
    end

    assert_response :success
    assert_select "h2", "OpenAI-compatible provider"
    assert_select "#image_to_texts", count: 0
  end

  test "index keeps an explicit provider tab over the runtime provider" do
    with_openai_env_cleared do
      with_env("IMAGE_DESCRIPTION_PROVIDER" => "openai") do
        get settings_image_to_texts_path(provider_tab: "local")
      end
    end

    assert_response :success
    assert_select "h2", "Local model"
  end

  test "index shows runtime openai model and base url from the environment without the key" do
    with_env(
      "IMAGE_DESCRIPTION_PROVIDER" => "openai",
      "OPENAI_API_BASE_URL" => "http://ollama.test:11434/v1",
      "OPENAI_VISION_MODEL" => "qwen3-vl:4b-instruct-q8_0",
      "OPENAI_API_KEY" => "sk-env-secret-9876"
    ) do
      get settings_image_to_texts_path(provider_tab: "local")
    end

    assert_response :success
    assert_select "#runtime-provider" do
      assert_select "[data-runtime='provider']", text: /OpenAI-compatible API/
      assert_select "[data-runtime='provider']", text: /IMAGE_DESCRIPTION_PROVIDER/
      assert_select "[data-runtime='model']", text: /qwen3-vl:4b-instruct-q8_0/
      assert_select "[data-runtime='model']", text: /OPENAI_VISION_MODEL/
      assert_select "[data-runtime='base-url']", text: %r{http://ollama\.test:11434/v1}
      assert_select "[data-runtime='base-url']", text: /OPENAI_API_BASE_URL/
    end
    assert_not_includes response.body, "sk-env-secret-9876"
  end

  test "index shows runtime openai values from saved settings" do
    with_openai_env_cleared do
      DescriptionProviderSetting.current.update!(
        provider: "openai", openai_base_url: "http://saved.test/v1", openai_model: "gpt-4.1-mini"
      )

      get settings_image_to_texts_path
    end

    assert_response :success
    assert_select "h2", "OpenAI-compatible provider"
    assert_select "#runtime-provider" do
      assert_select "[data-runtime='model']", text: /gpt-4\.1-mini/
      assert_select "[data-runtime='model']", text: /Saved setting/
      assert_select "[data-runtime='base-url']", text: %r{http://saved\.test/v1}
    end
  end

  test "index shows the current local model when the local provider is active" do
    image_to_texts(:two).update!(current: true)

    with_openai_env_cleared do
      get settings_image_to_texts_path(provider_tab: "openai")
    end

    assert_response :success
    assert_select "#runtime-provider" do
      assert_select "[data-runtime='provider']", text: /Local generator/
      assert_select "[data-runtime='model']", text: /Florence-2-large/
      assert_select "[data-runtime='base-url']", count: 0
    end
  end

  test "update_current saves local provider and selected local model" do
    model = image_to_texts(:one)
    DescriptionProviderSetting.current.update!(provider: "openai")

    post update_current_settings_image_to_texts_path, params: { current_id: model.id }

    assert_redirected_to settings_image_to_texts_path(provider_tab: "local")
    assert_equal "local", DescriptionProviderSetting.current.reload.provider
    assert model.reload.current?
  end

  test "update_current switches current model atomically" do
    previous_model = image_to_texts(:one)
    selected_model = image_to_texts(:two)
    previous_model.update!(current: true)
    selected_model.update!(current: false)
    DescriptionProviderSetting.current.update!(provider: "openai")

    post update_current_settings_image_to_texts_path, params: { current_id: selected_model.id }

    assert_redirected_to settings_image_to_texts_path(provider_tab: "local")
    assert_equal "local", DescriptionProviderSetting.current.reload.provider
    assert_not previous_model.reload.current?
    assert selected_model.reload.current?
  end

  test "update_current keeps selected model current when it was already current" do
    current_model = image_to_texts(:one)
    current_model.update!(current: true)
    DescriptionProviderSetting.current.update!(provider: "openai")

    post update_current_settings_image_to_texts_path, params: { current_id: current_model.id }

    assert_redirected_to settings_image_to_texts_path(provider_tab: "local")
    assert_equal "local", DescriptionProviderSetting.current.reload.provider
    assert current_model.reload.current?
    assert_equal 1, ImageToText.where(current: true).count
  end

  test "update_current preserves previous current model when selected model is missing" do
    current_model = image_to_texts(:one)
    current_model.update!(current: true)
    DescriptionProviderSetting.current.update!(provider: "openai")

    post update_current_settings_image_to_texts_path, params: { current_id: -1 }

    assert_redirected_to settings_image_to_texts_path(provider_tab: "local")
    assert_equal "local", DescriptionProviderSetting.current.reload.provider
    assert current_model.reload.current?
  end

  test "save_openai_settings saves cloud provider settings and redacts key" do
    post save_openai_settings_settings_image_to_texts_path, params: {
      description_provider_setting: {
        openai_base_url: "https://api.openai.com/v1",
        openai_model: "gpt-4.1-mini",
        openai_api_key: "sk-controller-1234abcd"
      }
    }

    assert_redirected_to settings_image_to_texts_path(provider_tab: "openai")
    setting = DescriptionProviderSetting.current.reload
    assert_equal "openai", setting.provider
    assert_equal "gpt-4.1-mini", setting.openai_model
    assert_equal "sk-controller-1234abcd", setting.openai_api_key
    assert_equal "sk-...abcd", setting.redacted_openai_api_key
  end

  test "save_openai_settings redirects with validation errors" do
    post save_openai_settings_settings_image_to_texts_path, params: {
      description_provider_setting: {
        openai_base_url: "https://api.openai.com/v1",
        openai_model: "m" * (DescriptionProviderSetting::OPENAI_MODEL_MAX_LENGTH + 1),
        openai_api_key: ""
      }
    }

    assert_redirected_to settings_image_to_texts_path(provider_tab: "openai")
    assert_match "Openai model is too long", flash[:alert]
  end

  test "save_openai_settings accepts a custom model for openai-compatible backends" do
    post save_openai_settings_settings_image_to_texts_path, params: {
      description_provider_setting: {
        openai_base_url: "http://ollama.test:11434/v1",
        openai_model: "qwen3-vl:4b-instruct-q8_0",
        openai_api_key: ""
      }
    }

    assert_redirected_to settings_image_to_texts_path(provider_tab: "openai")
    setting = DescriptionProviderSetting.current.reload
    assert_equal "openai", setting.provider
    assert_equal "qwen3-vl:4b-instruct-q8_0", setting.openai_model
  end

  test "index offers known cloud models as suggestions for a free text model field" do
    get settings_image_to_texts_path(provider_tab: "openai")

    assert_response :success
    assert_select "input[type=text][name='description_provider_setting[openai_model]'][list=openai-model-suggestions]"
    assert_select "datalist#openai-model-suggestions option", count: DescriptionProviderSetting.openai_model_options.size
    assert_select "datalist#openai-model-suggestions option[value='gpt-4o-mini']"
  end

  test "save_openai_settings resets stale connection test status" do
    setting = DescriptionProviderSetting.current
    setting.update!(
      provider: "openai",
      openai_base_url: "https://api.openai.com/v1",
      openai_model: "gpt-4o-mini",
      openai_last_test_status: "passed",
      openai_last_tested_at: Time.current,
      openai_last_test_error: nil
    )

    post save_openai_settings_settings_image_to_texts_path, params: {
      description_provider_setting: {
        openai_base_url: "https://api.openai.com/v1",
        openai_model: "gpt-4.1-mini",
        openai_api_key: ""
      }
    }

    setting.reload
    assert_equal "not_tested", setting.openai_last_test_status
    assert_nil setting.openai_last_tested_at
    assert_nil setting.openai_last_test_error
  end

  test "clear_openai_key removes saved key" do
    setting = DescriptionProviderSetting.current
    setting.openai_api_key = "sk-controller-1234abcd"
    setting.openai_last_test_status = "failed"
    setting.openai_last_tested_at = Time.current
    setting.openai_last_test_error = "401 Unauthorized"
    setting.save!

    delete clear_openai_key_settings_image_to_texts_path

    assert_redirected_to settings_image_to_texts_path(provider_tab: "openai")
    setting.reload
    assert_nil setting.openai_api_key
    assert_equal "Not saved", setting.redacted_openai_api_key
    assert_equal "not_tested", setting.openai_last_test_status
    assert_nil setting.openai_last_tested_at
    assert_nil setting.openai_last_test_error
  end

  test "test_openai_settings records passed status" do
    with_openai_env_cleared do
      setting = DescriptionProviderSetting.current
      setting.update!(provider: "openai", openai_base_url: "http://openai.test/v1", openai_model: "gpt-4o-mini")
      setting.openai_api_key = "sk-controller-1234abcd"
      setting.save!

      stub_request(:post, "http://openai.test/v1/chat/completions")
        .with { |request| openai_test_request_valid?(request) }
        .to_return(
          status: 200,
          body: { choices: [ { message: { content: "ok" } } ] }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      post test_openai_settings_settings_image_to_texts_path

      assert_redirected_to settings_image_to_texts_path(provider_tab: "openai")
      setting.reload
      assert_equal "passed", setting.openai_last_test_status
      assert_not_nil setting.openai_last_tested_at
      assert_nil setting.openai_last_test_error
    end
  end

  test "test_openai_settings records failed status for invalid JSON success response" do
    with_openai_env_cleared do
      setting = DescriptionProviderSetting.current
      setting.update!(provider: "openai", openai_base_url: "http://openai.test/v1", openai_model: "gpt-4o-mini")
      setting.openai_api_key = "sk-controller-1234abcd"
      setting.save!

      stub_request(:post, "http://openai.test/v1/chat/completions")
        .to_return(status: 200, body: "not json", headers: { "Content-Type" => "application/json" })

      post test_openai_settings_settings_image_to_texts_path

      assert_redirected_to settings_image_to_texts_path(provider_tab: "openai")
      setting.reload
      assert_equal "failed", setting.openai_last_test_status
      assert_equal "OpenAI connection test returned an unsupported response.", setting.openai_last_test_error
    end
  end

  test "test_openai_settings records failed status for blank success response content" do
    with_openai_env_cleared do
      setting = DescriptionProviderSetting.current
      setting.update!(provider: "openai", openai_base_url: "http://openai.test/v1", openai_model: "gpt-4o-mini")
      setting.openai_api_key = "sk-controller-1234abcd"
      setting.save!

      stub_request(:post, "http://openai.test/v1/chat/completions")
        .to_return(
          status: 200,
          body: { choices: [ { message: { content: "   " } } ] }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      post test_openai_settings_settings_image_to_texts_path

      assert_redirected_to settings_image_to_texts_path(provider_tab: "openai")
      setting.reload
      assert_equal "failed", setting.openai_last_test_status
      assert_equal "OpenAI connection test returned an unsupported response.", setting.openai_last_test_error
    end
  end

  test "test_openai_settings records failed status for missing success response content" do
    with_openai_env_cleared do
      setting = DescriptionProviderSetting.current
      setting.update!(provider: "openai", openai_base_url: "http://openai.test/v1", openai_model: "gpt-4o-mini")
      setting.openai_api_key = "sk-controller-1234abcd"
      setting.save!

      stub_request(:post, "http://openai.test/v1/chat/completions")
        .to_return(
          status: 200,
          body: { choices: [ { message: {} } ] }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      post test_openai_settings_settings_image_to_texts_path

      assert_redirected_to settings_image_to_texts_path(provider_tab: "openai")
      setting.reload
      assert_equal "failed", setting.openai_last_test_status
      assert_equal "OpenAI connection test returned an unsupported response.", setting.openai_last_test_error
    end
  end

  test "test_openai_settings records failed status" do
    with_openai_env_cleared do
      setting = DescriptionProviderSetting.current
      setting.update!(provider: "openai", openai_base_url: "http://openai.test/v1", openai_model: "gpt-4o-mini")
      setting.openai_api_key = "sk-controller-1234abcd"
      setting.save!

      stub_request(:post, "http://openai.test/v1/chat/completions")
        .to_return(status: 429, body: { error: { message: "rate limited" } }.to_json)

      post test_openai_settings_settings_image_to_texts_path

      assert_redirected_to settings_image_to_texts_path(provider_tab: "openai")
      setting.reload
      assert_equal "failed", setting.openai_last_test_status
      assert_match "429", setting.openai_last_test_error
    end
  end

  test "test_openai_settings records missing key without sending request" do
    with_openai_env_cleared do
      setting = DescriptionProviderSetting.current
      setting.update!(provider: "openai", openai_base_url: "http://openai.test/v1", openai_model: "gpt-4o-mini")
      setting.clear_openai_api_key
      setting.save!

      post test_openai_settings_settings_image_to_texts_path

      assert_redirected_to settings_image_to_texts_path(provider_tab: "openai")
      setting.reload
      assert_equal "failed", setting.openai_last_test_status
      assert_match "OPENAI_API_KEY", setting.openai_last_test_error
      assert_not_requested :post, "http://openai.test/v1/chat/completions"
    end
  end

  private

    def with_openai_env_cleared(&block)
      with_env({
        "IMAGE_DESCRIPTION_PROVIDER" => nil,
        "OPENAI_API_BASE_URL" => nil,
        "OPENAI_API_KEY" => nil,
        "OPENAI_VISION_MODEL" => nil
      }, &block)
    end

    def with_env(values)
      old_values = values.keys.to_h { |key| [ key, ENV[key] ] }
      values.each do |key, value|
        value.nil? ? ENV.delete(key) : ENV[key] = value
      end
      yield
    ensure
      old_values.each do |key, value|
        value.nil? ? ENV.delete(key) : ENV[key] = value
      end
    end

    def openai_test_request_valid?(request)
      body = JSON.parse(request.body)
      content = body.dig("messages", 0, "content")
      image_url = content&.find { |item| item["type"] == "image_url" }&.dig("image_url", "url")

      request.headers["Authorization"] == "Bearer sk-controller-1234abcd" &&
        body["model"] == "gpt-4o-mini" &&
        body["max_tokens"] == 5 &&
        content.any? { |item| item["type"] == "text" } &&
        image_url&.start_with?("data:image/png;base64,") &&
        image_url != "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMB/ay+K6EAAAAASUVORK5CYII="
    end
end
