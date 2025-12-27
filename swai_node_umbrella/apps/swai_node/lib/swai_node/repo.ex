defmodule SwaiNode.Repo do
  use Ecto.Repo,
    otp_app: :swai_node,
    adapter: Ecto.Adapters.SQLite3
end
