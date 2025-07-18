import Config

config :block_scout_web, :sql_sandbox, true

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :block_scout_web, BlockScoutWeb.Endpoint,
  http: [port: 4002],
  secret_key_base: "27Swe6KtEtmN37WyEYRjKWyxYULNtrxlkCEKur4qoV+Lwtk8lafsR16ifz1XBBYj",
  server: true,
  pubsub_server: BlockScoutWeb.PubSub,
  checksum_address_hashes: true

config :block_scout_web, BlockScoutWeb.Tracer, disabled?: false

config :logger, :block_scout_web,
  level: :warn,
  path: Path.absname("logs/test/block_scout_web.log")

# Configure wallaby
config :wallaby, screenshot_on_failure: true, driver: Wallaby.Chrome, js_errors: false

config :block_scout_web, BlockScoutWeb.Counters.BlocksIndexedCounter, enabled: false

config :block_scout_web, BlockScoutWeb.Counters.InternalTransactionsIndexedCounter, enabled: false

config :tesla, adapter: Explorer.Mock.TeslaAdapter

config :ueberauth, Ueberauth,
  providers: [
    auth0: {
      Ueberauth.Strategy.Auth0,
      [callback_url: "example.com/callback"]
    }
  ]
