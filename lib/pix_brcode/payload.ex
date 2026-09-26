defmodule PixBrcode.Payload do
  @moduledoc """
  A decoded Pix payload.

  `:type` is `:static` (has a `:key`) or `:dynamic` (has a `:url`).
  `:amount` is kept as the string found in the payload, e.g. `"10.50"`.
  """

  @type t :: %__MODULE__{
          type: :static | :dynamic,
          key: String.t() | nil,
          url: String.t() | nil,
          description: String.t() | nil,
          amount: String.t() | nil,
          merchant_name: String.t() | nil,
          merchant_city: String.t() | nil,
          txid: String.t() | nil
        }

  defstruct [:type, :key, :url, :description, :amount, :merchant_name, :merchant_city, :txid]
end
