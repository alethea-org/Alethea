defmodule Alethea.AI.SanitizerTest do
  use ExUnit.Case, async: true

  alias Alethea.AI.Sanitizer

  describe "sanitize/1" do
    test "returns empty string for nil input" do
      assert Sanitizer.sanitize(nil) == ""
    end

    test "returns empty string for blank input" do
      assert Sanitizer.sanitize("") == ""
      assert Sanitizer.sanitize("   ") == ""
      assert Sanitizer.sanitize("\n\t") == ""
    end

    test "trims whitespace from input" do
      assert Sanitizer.sanitize("  hello world  ") == "hello world"
    end
  end

  describe "email redaction" do
    test "redacts standard email addresses" do
      text = "Mi email es juan@ejemplo.com y me pueden contactar ahí."
      assert Sanitizer.sanitize(text) == "Mi email es [REDACTED_EMAIL] y me pueden contactar ahí."
    end

    test "redacts multiple email addresses" do
      text = "Contactar a pedro@test.com o maria@test.org"
      result = Sanitizer.sanitize(text)
      assert result == "Contactar a [REDACTED_EMAIL] o [REDACTED_EMAIL]"
    end

    test "redacts emails with subdomains" do
      text = "Mi correo institucional es user@mail.dominio.cl"
      assert Sanitizer.sanitize(text) == "Mi correo institucional es [REDACTED_EMAIL]"
    end

    test "redacts emails with plus addressing" do
      text = "Email: nombre+test@gmail.com"
      assert Sanitizer.sanitize(text) == "Email: [REDACTED_EMAIL]"
    end

    test "does not redact partial email-like strings" do
      # This is a sentence that has 'test' followed by '.com' as separate words
      text = "El test comía cuando llegó el paquete"
      assert Sanitizer.sanitize(text) == text
    end
  end

  describe "phone redaction" do
    test "redacts Chilean mobile numbers" do
      text = "Mi celular es +56912345678"
      assert Sanitizer.sanitize(text) == "Mi celular es [REDACTED_PHONE]"
    end

    test "redacts numbers with spaces" do
      text = "Llamar al +56 9 1234 5678"
      assert Sanitizer.sanitize(text) == "Llamar al [REDACTED_PHONE]"
    end

    test "redacts numbers with dashes" do
      text = "Teléfono: +56-9-1234-5678"
      assert Sanitizer.sanitize(text) == "Teléfono: [REDACTED_PHONE]"
    end

    test "redacts local phone numbers" do
      text = "Mi número fijo es 224567890"
      assert Sanitizer.sanitize(text) == "Mi número fijo es [REDACTED_PHONE]"
    end

    test "redacts international format" do
      text = "Desde USA: +1 (555) 123-4567"
      result = Sanitizer.sanitize(text)
      # The number should be redacted - either fully or partially
      assert result =~ "REDACTED",
             "Expected phone to be redacted, got: #{result}"

      # The original formatted number should NOT remain intact
      refute result =~ "+1 (555) 123-4567"
    end
  end

  describe "SSN redaction" do
    test "redacts US SSN format" do
      text = "Su SSN es 123-45-6789"
      assert Sanitizer.sanitize(text) == "Su SSN es [REDACTED_SSN]"
    end

    test "redacts multiple SSNs" do
      text = "SSN 1: 111-22-3333, SSN 2: 444-55-6666"
      result = Sanitizer.sanitize(text)
      assert result == "SSN 1: [REDACTED_SSN], SSN 2: [REDACTED_SSN]"
    end
  end

  describe "document ID redaction" do
    test "redacts 9-digit document numbers" do
      text = "RUT: 123456789"
      assert Sanitizer.sanitize(text) == "RUT: [REDACTED_ID]"
    end

    test "does not redact numbers less than 9 digits" do
      text = "Código: 12345"
      assert Sanitizer.sanitize(text) == text
    end

    test "does not redact numbers more than 9 digits" do
      text = "Referencia: 1234567890"
      # This has 10 digits, so should NOT be redacted by the document_id pattern
      assert Sanitizer.sanitize(text) == text
    end
  end

  describe "combined redaction" do
    test "redacts multiple PII types in same text" do
      text = """
      Paciente: María González
      Email: maria@test.cl
      Teléfono: +56912345678
      RUT: 123456789
      """

      result = Sanitizer.sanitize(text)

      refute result =~ "maria@test.cl"
      refute result =~ "+56912345678"
      refute result =~ "123456789"
      assert result =~ "[REDACTED_EMAIL]"
      assert result =~ "[REDACTED_PHONE]"
      assert result =~ "[REDACTED_ID]"
    end

    test "preserves non-PII content" do
      text = "El paciente menciona que se siente triste desde hace 3 semanas"

      assert Sanitizer.sanitize(text) == text
    end
  end

  describe "edge cases" do
    test "handles unicode correctly" do
      text = "Paciente: José María Ñoño, email: jose@test.cl"
      result = Sanitizer.sanitize(text)

      assert result =~ "José María Ñoño"
      assert result =~ "[REDACTED_EMAIL]"
    end

    test "handles very long text" do
      text = String.duplicate("Mensaje de prueba. ", 1000) <> "email@test.com"
      result = Sanitizer.sanitize(text)

      assert result =~ "[REDACTED_EMAIL]"
      refute result =~ "email@test.com"
    end

    test "handles text with newlines and tabs" do
      text = """
      Email: test@example.com
      Tel: +56912345678
      """

      result = Sanitizer.sanitize(text)
      refute result =~ "test@example.com"
      refute result =~ "+56912345678"
    end

    test "handles HTML content" do
      text = "Email: <script>test@test.com</script>"
      result = Sanitizer.sanitize(text)

      # The regex should still match within the HTML
      assert result =~ "[REDACTED_EMAIL]"
    end
  end
end
