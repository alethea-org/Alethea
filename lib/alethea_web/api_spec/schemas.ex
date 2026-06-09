defmodule AletheaWeb.Schemas do
  @moduledoc """
  Schema definitions for OpenAPI documentation.

  This module defines all schemas used in the API specification,
  including request/response bodies, error formats, and data models.
  """

  alias OpenApiSpex.Schema

  # ============================================
  # Error Response Schemas
  # ============================================

  defmodule ErrorResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "ErrorResponse",
      type: :object,
      properties: %{
        error: %Schema{type: :string, description: "Error message", example: "An error occurred"},
        code: %Schema{type: :string, description: "Error code", example: "ERROR_CODE"}
      },
      required: [:error]
    })
  end

  defmodule UnauthorizedResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "UnauthorizedResponse",
      type: :object,
      properties: %{
        error: %Schema{
          type: :string,
          description: "Authentication required message",
          example: "Authentication required"
        }
      },
      required: [:error]
    })
  end

  defmodule ForbiddenResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "ForbiddenResponse",
      type: :object,
      properties: %{
        error: %Schema{
          type: :string,
          description: "Access denied message",
          example: "Access denied"
        }
      },
      required: [:error]
    })
  end

  defmodule NotFoundResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "NotFoundResponse",
      type: :object,
      properties: %{
        error: %Schema{
          type: :string,
          description: "Resource not found message",
          example: "Resource not found"
        }
      },
      required: [:error]
    })
  end

  defmodule ValidationErrorResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "ValidationErrorResponse",
      type: :object,
      properties: %{
        errors: %Schema{
          type: :array,
          items: %Schema{
            type: :object,
            properties: %{
              field: %Schema{type: :string, example: "email"},
              message: %Schema{type: :string, example: "is invalid"}
            }
          },
          description: "List of validation errors"
        }
      },
      required: [:errors]
    })
  end

  defmodule ServerErrorResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "ServerErrorResponse",
      type: :object,
      properties: %{
        error: %Schema{
          type: :string,
          description: "Internal server error message",
          example: "Internal server error"
        }
      },
      required: [:error]
    })
  end

  # ============================================
  # Authentication Schemas
  # ============================================

  defmodule LoginRequest do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "LoginRequest",
      type: :object,
      properties: %{
        email: %Schema{
          type: :string,
          format: :email,
          description: "Professional's email address",
          example: "doctor@clinic.com"
        },
        password: %Schema{type: :string, format: :password, description: "Account password"},
        remember_me: %Schema{
          type: :boolean,
          description: "Remember login for 30 days",
          default: false
        }
      },
      required: [:email, :password]
    })
  end

  defmodule LoginResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "LoginResponse",
      type: :object,
      properties: %{
        message: %Schema{
          type: :string,
          description: "Success message",
          example: "Login successful"
        },
        professional: %Schema{
          type: :object,
          properties: %{
            id: %Schema{type: :integer, description: "Professional ID"},
            name: %Schema{type: :string, description: "Professional name"},
            email: %Schema{type: :string, format: :email}
          }
        }
      }
    })
  end

  defmodule RegisterRequest do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "RegisterRequest",
      type: :object,
      properties: %{
        name: %Schema{
          type: :string,
          description: "Professional's full name",
          example: "Dr. Jane Smith"
        },
        email: %Schema{
          type: :string,
          format: :email,
          description: "Professional's email address",
          example: "doctor@clinic.com"
        },
        password: %Schema{
          type: :string,
          format: :password,
          description: "Account password (min 8 characters)"
        },
        clinic_name: %Schema{
          type: :string,
          description: "Name of the clinic/practice",
          example: "Health & Wellness Clinic"
        }
      },
      required: [:name, :email, :password, :clinic_name]
    })
  end

  defmodule RegisterResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "RegisterResponse",
      type: :object,
      properties: %{
        message: %Schema{
          type: :string,
          description: "Registration success message",
          example: "Registration successful"
        },
        professional: %Schema{
          type: :object,
          properties: %{
            id: %Schema{type: :integer, description: "Professional ID"},
            name: %Schema{type: :string},
            email: %Schema{type: :string, format: :email}
          }
        }
      }
    })
  end

  # ============================================
  # Patient Schemas
  # ============================================

  defmodule Patient do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "Patient",
      type: :object,
      properties: %{
        id: %Schema{type: :integer, description: "Patient ID"},
        name: %Schema{type: :string, description: "Patient full name"},
        email: %Schema{type: :string, format: :email, description: "Patient email"},
        phone: %Schema{type: :string, description: "Patient phone number"},
        whatsapp_id: %Schema{type: :string, description: "WhatsApp contact ID"},
        created_at: %Schema{
          type: :string,
          format: :"date-time",
          description: "Patient creation timestamp"
        },
        notes: %Schema{type: :string, description: "Clinical notes about the patient"}
      }
    })
  end

  defmodule PatientListResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "PatientListResponse",
      type: :object,
      properties: %{
        patients: %Schema{type: :array, items: Patient, description: "List of patients"},
        total: %Schema{type: :integer, description: "Total number of patients"}
      }
    })
  end

  defmodule PatientResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "PatientResponse",
      type: :object,
      properties: %{
        patient: Patient
      }
    })
  end

  # ============================================
  # WhatsApp Webhook Schemas
  # ============================================

  defmodule WhatsAppMessage do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "WhatsAppMessage",
      type: :object,
      properties: %{
        from: %Schema{
          type: :string,
          description: "Sender's WhatsApp ID",
          example: "5491123456789"
        },
        to: %Schema{
          type: :string,
          description: "Recipient's WhatsApp ID",
          example: "5491500000000"
        },
        type: %Schema{
          type: :string,
          enum: ["text", "image", "audio", "video", "document", "location", "contacts"],
          description: "Message type"
        },
        text: %Schema{
          type: :object,
          properties: %{
            body: %Schema{type: :string, description: "Message text content"}
          }
        },
        timestamp: %Schema{type: :string, description: "Unix timestamp of message"}
      },
      required: [:from, :type]
    })
  end

  defmodule WhatsAppWebhookRequest do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "WhatsAppWebhookRequest",
      type: :object,
      properties: %{
        messages: %Schema{type: :array, items: WhatsAppMessage, description: "List of messages"},
        contacts: %Schema{
          type: :array,
          items: %Schema{type: :object},
          description: "Contact information"
        }
      }
    })
  end

  defmodule WhatsAppVerificationRequest do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "WhatsAppVerificationRequest",
      type: :object,
      properties: %{
        "hub.mode": %Schema{
          type: :string,
          enum: ["subscribe"],
          description: "Webhook verification mode"
        },
        "hub.verify_token": %Schema{
          type: :string,
          description: "Verification token from WhatsApp"
        },
        "hub.challenge": %Schema{type: :string, description: "Challenge string to return"}
      },
      required: [:"hub.mode", :"hub.verify_token", :"hub.challenge"]
    })
  end

  defmodule WhatsAppWebhookResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "WhatsAppWebhookResponse",
      type: :object,
      properties: %{
        status: %Schema{type: :string, description: "Webhook processing status", example: "ok"}
      }
    })
  end

  # ============================================
  # Schema Registry
  # ============================================

  def schemas do
    %{
      "ErrorResponse" => ErrorResponse,
      "UnauthorizedResponse" => UnauthorizedResponse,
      "ForbiddenResponse" => ForbiddenResponse,
      "NotFoundResponse" => NotFoundResponse,
      "ValidationErrorResponse" => ValidationErrorResponse,
      "ServerErrorResponse" => ServerErrorResponse,
      "LoginRequest" => LoginRequest,
      "LoginResponse" => LoginResponse,
      "RegisterRequest" => RegisterRequest,
      "RegisterResponse" => RegisterResponse,
      "Patient" => Patient,
      "PatientListResponse" => PatientListResponse,
      "PatientResponse" => PatientResponse,
      "WhatsAppMessage" => WhatsAppMessage,
      "WhatsAppWebhookRequest" => WhatsAppWebhookRequest,
      "WhatsAppVerificationRequest" => WhatsAppVerificationRequest,
      "WhatsAppWebhookResponse" => WhatsAppWebhookResponse
    }
  end
end
