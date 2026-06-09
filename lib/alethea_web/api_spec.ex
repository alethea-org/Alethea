defmodule AletheaWeb.ApiSpec do
  @moduledoc """
  OpenAPI specification for Alethea API.

  This module defines the API schemas, endpoints, and paths for:
  - Webhook endpoints (WhatsApp integration)
  - Authentication flows (login, logout, register)
  - Error responses

  The spec is used to generate Swagger UI at /api-docs and the openapi.json file.
  """

  alias OpenApiSpex.{
    Info,
    PathItem,
    Schema,
    Response,
    Operation,
    RequestBody,
    MediaType,
    Parameter
  }

  alias AletheaWeb.Schemas

  @behaviour OpenApiSpex.OpenApi

  @impl true
  def spec do
    %OpenApiSpex.OpenApi{
      info: info(),
      servers: servers(),
      tags: tags(),
      paths: paths(),
      components: components()
    }
  end

  def info do
    %Info{
      title: "Alethea API",
      version: "1.0.0",
      description: """
      Alethea is a clinical support platform for mental health professionals.

      This API provides endpoints for:
      - WhatsApp webhook integration for patient messaging
      - Authentication (login, logout, registration)
      - Patient management (CRUD operations)

      All endpoints except webhooks require authentication via session cookies.
      """,
      contact: %{
        name: "Alethea Support",
        email: "support@alethea.health"
      }
    }
  end

  def servers do
    [
      %OpenApiSpex.Server{
        url: System.get_env("API_BASE_URL", "http://localhost:4000"),
        description: "Local development server"
      }
    ]
  end

  def tags do
    [
      %OpenApiSpex.Tag{name: "Webhooks", description: "WhatsApp webhook integration endpoints"},
      %OpenApiSpex.Tag{
        name: "Authentication",
        description: "User authentication and session management"
      },
      %OpenApiSpex.Tag{name: "Patients", description: "Patient CRUD operations"}
    ]
  end

  def paths do
    %{
      "/webhooks/whatsapp" => %PathItem{
        get: %Operation{
          tags: ["Webhooks"],
          summary: "Verify WhatsApp webhook",
          description: "Verifies the webhook endpoint with WhatsApp servers.",
          parameters: [
            %Parameter{
              name: "hub.mode",
              in: :query,
              required: true,
              schema: %Schema{type: :string, enum: ["subscribe"]},
              description: "Webhook verification mode"
            },
            %Parameter{
              name: "hub.verify_token",
              in: :query,
              required: true,
              schema: %Schema{type: :string},
              description: "Verification token"
            },
            %Parameter{
              name: "hub.challenge",
              in: :query,
              required: true,
              schema: %Schema{type: :string},
              description: "Challenge string to return"
            }
          ],
          responses: %{
            200 => %Response{description: "Webhook verified successfully"},
            403 => %Response{description: "Invalid verification token"}
          }
        },
        post: %Operation{
          tags: ["Webhooks"],
          summary: "Receive WhatsApp messages",
          description: "Receives incoming messages and events from WhatsApp.",
          requestBody: %RequestBody{
            required: true,
            content: %{"application/json" => %MediaType{schema: Schemas.WhatsAppWebhookRequest}}
          },
          responses: %{
            200 => %Response{
              description: "Message received and queued for processing",
              content: %{
                "application/json" => %MediaType{schema: Schemas.WhatsAppWebhookResponse}
              }
            }
          }
        }
      },
      "/login" => %PathItem{
        get: %Operation{
          tags: ["Authentication"],
          summary: "Show login form",
          description: "Returns the login page HTML form.",
          responses: %{200 => %Response{description: "Login form page"}}
        },
        post: %Operation{
          tags: ["Authentication"],
          summary: "Authenticate user",
          description: "Authenticates a professional and creates a session.",
          requestBody: %RequestBody{
            required: true,
            content: %{
              "application/x-www-form-urlencoded" => %MediaType{schema: Schemas.LoginRequest}
            }
          },
          responses: %{
            302 => %Response{description: "Authentication successful, redirect to dashboard"},
            401 => %Response{description: "Invalid credentials"}
          }
        }
      },
      "/logout" => %PathItem{
        delete: %Operation{
          tags: ["Authentication"],
          summary: "Logout user",
          description: "Logs out the current professional by clearing the session.",
          responses: %{
            302 => %Response{description: "Logout successful, redirect to login"},
            401 => %Response{description: "No active session"}
          }
        }
      },
      "/register" => %PathItem{
        get: %Operation{
          tags: ["Authentication"],
          summary: "Show registration form",
          description: "Returns the registration page HTML form.",
          responses: %{200 => %Response{description: "Registration form page"}}
        },
        post: %Operation{
          tags: ["Authentication"],
          summary: "Register new professional",
          description: "Registers a new professional account.",
          requestBody: %RequestBody{
            required: true,
            content: %{
              "application/x-www-form-urlencoded" => %MediaType{schema: Schemas.RegisterRequest}
            }
          },
          responses: %{
            302 => %Response{description: "Registration successful, redirect to dashboard"},
            422 => %Response{description: "Validation errors (email already exists, etc.)"}
          }
        }
      },
      "/patients" => %PathItem{
        get: %Operation{
          tags: ["Patients"],
          summary: "List patients",
          description: "Returns a paginated list of patients for the authenticated professional.",
          responses: %{
            200 => %Response{description: "List of patients"},
            401 => %Response{description: "Authentication required"}
          }
        }
      },
      "/dashboard/patients/{id}" => %PathItem{
        get: %Operation{
          tags: ["Patients"],
          summary: "Show patient details",
          description: "Returns detailed information about a specific patient.",
          parameters: [
            %Parameter{
              name: "id",
              in: :path,
              required: true,
              schema: %Schema{type: :integer},
              description: "Patient ID"
            }
          ],
          responses: %{
            200 => %Response{description: "Patient details page"},
            401 => %Response{description: "Authentication required"},
            404 => %Response{description: "Patient not found"}
          }
        }
      }
    }
  end

  def components do
    %OpenApiSpex.Components{
      schemas: Schemas.schemas(),
      responses: %{
        "400" => %Response{
          description: "Bad Request - Invalid request parameters",
          content: %{"application/json" => %MediaType{schema: Schemas.ErrorResponse}}
        },
        "401" => %Response{
          description: "Unauthorized - Authentication required",
          content: %{"application/json" => %MediaType{schema: Schemas.UnauthorizedResponse}}
        },
        "403" => %Response{
          description: "Forbidden - Access denied",
          content: %{"application/json" => %MediaType{schema: Schemas.ForbiddenResponse}}
        },
        "404" => %Response{
          description: "Not Found - Resource not found",
          content: %{"application/json" => %MediaType{schema: Schemas.NotFoundResponse}}
        },
        "422" => %Response{
          description: "Unprocessable Entity - Validation failed",
          content: %{"application/json" => %MediaType{schema: Schemas.ValidationErrorResponse}}
        },
        "500" => %Response{
          description: "Internal Server Error",
          content: %{"application/json" => %MediaType{schema: Schemas.ServerErrorResponse}}
        }
      }
    }
  end
end
