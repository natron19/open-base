require "gemini-ai"

class GeminiService
  class GeminiError         < StandardError; end
  class GatekeeperError     < GeminiError;   end
  class BudgetExceededError < GeminiError;   end
  class TimeoutError        < GeminiError;   end

  TIMEOUT_SECONDS = ENV.fetch("AI_GLOBAL_TIMEOUT_SECONDS", "15").to_i

  def self.generate(template:, variables: {}, user: Current.user)
    new(template:, variables:, user:).generate
  end

  def initialize(template:, variables: {}, user:)
    @template_name = template
    @variables     = variables
    @user          = user
  end

  def generate
    ai_template     = AiTemplate.find_by!(name: @template_name)
    rendered_prompt = ai_template.interpolate(@variables)

    begin
      AiGatekeeper.check!(rendered_prompt, @user)
    rescue GatekeeperError => e
      LlmRequest.create!(
        user: @user, ai_template: ai_template, template_name: ai_template.name,
        status: "gatekeeper_blocked", error_message: e.message
      ) if @user
      raise
    end

    if @user
      begin
        AiBudgetChecker.check!(@user)
      rescue BudgetExceededError => e
        LlmRequest.create!(
          user: @user, ai_template: ai_template, template_name: ai_template.name,
          status: "budget_exceeded", error_message: e.message
        )
        raise
      end
    end

    log = LlmRequest.create!(
      user:          @user,
      ai_template:   ai_template,
      template_name: ai_template.name,
      status:        "pending"
    )

    start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    begin
      response_text, prompt_tokens, response_tokens = call_gemini(ai_template, rendered_prompt)
      duration_ms = elapsed_ms(start_time)

      log.update!(
        status:               "success",
        prompt_token_count:   prompt_tokens,
        response_token_count: response_tokens,
        duration_ms:          duration_ms,
        cost_estimate_cents:  estimate_cost(prompt_tokens, response_tokens, ai_template.model)
      )

      response_text

    rescue Timeout::Error
      log.update!(
        status:        "timeout",
        duration_ms:   elapsed_ms(start_time),
        error_message: "Gemini call timed out after #{TIMEOUT_SECONDS}s"
      )
      raise TimeoutError, "The AI request timed out. Please try again."

    rescue GeminiError
      raise

    rescue => e
      log.update!(
        status:        "error",
        duration_ms:   elapsed_ms(start_time),
        error_message: e.message.truncate(500)
      )
      raise GeminiError, "An error occurred while generating a response."
    end
  end

  private

  def call_gemini(ai_template, rendered_prompt)
    client = Gemini.new(
      credentials: {
        service: "generative-language-api",
        api_key:  ENV.fetch("GEMINI_API_KEY")
      },
      options: { model: ai_template.model, server_sent_events: false }
    )

    result = Timeout.timeout(TIMEOUT_SECONDS) do
      client.generate_content({
        contents: { role: "user", parts: { text: rendered_prompt } },
        system_instruction: { role: "user", parts: { text: ai_template.system_prompt } },
        generationConfig: {
          maxOutputTokens: ai_template.max_output_tokens,
          temperature:     ai_template.temperature.to_f
        }
      })
    end

    text = result.dig("candidates", 0, "content", "parts", 0, "text") || ""
    prompt_tokens   = result.dig("usageMetadata", "promptTokenCount")   || estimate_tokens(rendered_prompt)
    response_tokens = result.dig("usageMetadata", "candidatesTokenCount") || estimate_tokens(text)

    [text, prompt_tokens, response_tokens]
  end

  def estimate_tokens(text)
    (text.to_s.length / 4.0).ceil
  end

  def estimate_cost(prompt_tokens, response_tokens, model)
    # gemini-2.0-flash approximate pricing in cents per 1M tokens
    input_rate  = 7.5
    output_rate = 30.0
    ((prompt_tokens * input_rate) + (response_tokens * output_rate)) / 1_000_000.0
  end

  def elapsed_ms(start)
    ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - start) * 1000).round
  end
end
