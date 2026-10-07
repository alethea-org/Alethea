import Config

# Force using SSL in production. This also sets the "strict-transport-security"
# header, known as HSTS.
# Note `:force_ssl` is required to be set at compile-time.
#
# The health paths are excluded from the redirect: platform checks reach the
# internal HTTP port directly, without `x-forwarded-proto`, and a 301 would
# read as a failed check. Every other request is still redirected and still
# gets HSTS. Setting `:exclude` replaces the Plug.SSL default, so the local
# hosts are listed again explicitly.
config :alethea, AletheaWeb.Endpoint,
  force_ssl: [
    rewrite_on: [:x_forwarded_proto],
    exclude: [
      paths: ["/health", "/health/ready"],
      hosts: ["localhost", "127.0.0.1"]
    ]
  ]

# Do not print debug messages in production
config :logger, level: :info

# Runtime production configuration, including reading
# of environment variables, is done on config/runtime.exs.
