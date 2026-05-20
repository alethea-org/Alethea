defmodule Alethea.AI.SanitizerTest do
  use ExUnit.Case, async: true

  alias Alethea.AI.Sanitizer

  describe "sanitize/1" do
    test "redacts email, phone, and document ids" do
      input = "Mi correo es juan@example.com y mi teléfono +1 555-123-4567. Mi ID es 123456789."

      output = Sanitizer.sanitize(input)

      assert output =~ "[REDACTED_EMAIL]"
      assert output =~ "[REDACTED_PHONE]"
      assert output =~ "[REDACTED_ID]"
      refute output =~ "juan@example.com"
      refute output =~ "+1 555-123-4567"
      refute output =~ "123456789"
    end

    test "returns empty string for nil input" do
      assert Sanitizer.sanitize(nil) == ""
    end
  end
end
