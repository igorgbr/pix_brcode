defmodule PixBrcode do
  @moduledoc """
  Generates and reads Pix "copia e cola" payloads (BR Code).
  """

  alias PixBrcode.{CRC16, Payload, TLV}

  @gui "br.gov.bcb.pix"

  @doc """
  Builds a static Pix payload.

  Required: `:key`, `:merchant_name` (max 25 chars), `:merchant_city` (max 15 chars).
  Optional: `:amount` (`"10.50"` or integer cents `1050`), `:txid` (default `"***"`),
  `:description`. Accents in name and city are removed.

      iex> PixBrcode.encode(%{key: "123e4567-e12b-12d1-a456-426655440000",
      ...>   merchant_name: "Fulano de Tal", merchant_city: "BRASILIA"})
      {:ok, "00020126580014br.gov.bcb.pix0136123e4567-e12b-12d1-a456-4266554400005204000053039865802BR5913Fulano de Tal6008BRASILIA62070503***63041D3D"}
  """
  def encode(%{key: key, merchant_name: name, merchant_city: city} = params)
      when is_binary(key) and is_binary(name) and is_binary(city) do
    txid = Map.get(params, :txid) || "***"
    description = Map.get(params, :description)

    with :ok <- check(valid_key?(key), :invalid_key),
         :ok <- check(txid == "***" or txid =~ ~r/\A[A-Za-z0-9]{1,25}\z/, :invalid_txid),
         :ok <- check(is_nil(description) or clean(description, 99) != nil, :invalid_description),
         {:ok, amount} <- format_amount(Map.get(params, :amount)) do
      build(params, [{"01", key}, {"02", description && clean(description, 99)}], amount, txid)
    end
  end

  def encode(_params), do: {:error, :missing_required_fields}

  @doc """
  Builds a dynamic Pix payload, pointing to a URL provided by the receiver's bank.

  Required: `:url` (without `https://`), `:merchant_name`, `:merchant_city`.
  Amount and txid live in the bank's server, not in the payload.

      iex> {:ok, payload} = PixBrcode.encode_dynamic(%{url: "pix.example.com/qr/v2/abc",
      ...>   merchant_name: "Fulano de Tal", merchant_city: "BRASILIA"})
      iex> PixBrcode.decode(payload) |> elem(1) |> Map.take([:type, :url])
      %{type: :dynamic, url: "pix.example.com/qr/v2/abc"}
  """
  def encode_dynamic(%{url: url, merchant_name: name, merchant_city: city} = params)
      when is_binary(url) and is_binary(name) and is_binary(city) do
    with :ok <- check(url != "" and not String.contains?(url, "://"), :invalid_url) do
      build(params, [{"25", url}], nil, "***")
    end
  end

  def encode_dynamic(_params), do: {:error, :missing_required_fields}

  # Shared by both encoders: validates name/city, assembles the fields and appends the CRC.
  defp build(%{merchant_name: name, merchant_city: city}, account_fields, amount, txid) do
    name = clean(name, 25)
    city = clean(city, 15)

    with :ok <- check(name != nil, :invalid_merchant_name),
         :ok <- check(city != nil, :invalid_merchant_city),
         {:ok, account} <- TLV.encode([{"00", @gui} | account_fields]),
         {:ok, additional} <- TLV.encode([{"05", txid}]),
         {:ok, payload} <-
           TLV.encode([
             {"00", "01"},
             {"26", account},
             {"52", "0000"},
             {"53", "986"},
             {"54", amount},
             {"58", "BR"},
             {"59", name},
             {"60", city},
             {"62", additional}
           ]) do
      payload = payload <> "6304"
      {:ok, payload <> CRC16.checksum(payload)}
    end
  end

  @doc """
  Reads a Pix payload, checking CRC, structure and GUI.

      iex> {:ok, payload} = PixBrcode.decode("00020126580014br.gov.bcb.pix0136123e4567-e12b-12d1-a456-4266554400005204000053039865802BR5913Fulano de Tal6008BRASILIA62070503***63041D3D")
      iex> {payload.type, payload.key, payload.merchant_name}
      {:static, "123e4567-e12b-12d1-a456-426655440000", "Fulano de Tal"}
  """
  def decode(payload) when is_binary(payload) do
    payload = String.trim(payload)
    {data, crc} = String.split_at(payload, -4)

    with :ok <-
           check(
             String.ends_with?(data, "6304") and String.upcase(crc) == CRC16.checksum(data),
             :invalid_crc
           ),
         {:ok, fields} <- TLV.decode(payload),
         :ok <-
           check(
             match?([{"00", "01"} | _], fields) and match?({"63", _}, List.last(fields)),
             :invalid_format
           ),
         fields = Map.new(fields),
         {:ok, account} <- TLV.decode(Map.get(fields, "26", "")),
         account = Map.new(account),
         # Banks differ in case (Nubank sends "BR.GOV.BCB.PIX"), so compare case-insensitively.
         :ok <- check(String.downcase(account["00"] || "") == @gui, :invalid_gui),
         :ok <- check(Map.has_key?(account, "01") or Map.has_key?(account, "25"), :missing_key),
         :ok <- check(is_nil(account["01"]) or valid_key?(account["01"]), :invalid_key),
         {:ok, additional} <- TLV.decode(Map.get(fields, "62", "")) do
      {:ok,
       %Payload{
         type: if(Map.has_key?(account, "25"), do: :dynamic, else: :static),
         key: account["01"],
         url: account["25"],
         description: account["02"],
         amount: fields["54"],
         merchant_name: fields["59"],
         merchant_city: fields["60"],
         txid: additional |> Map.new() |> Map.get("05")
       }}
    end
  end

  def decode(_payload), do: {:error, :invalid_format}

  @doc """
  Returns `true` if `payload` decodes successfully.

      iex> PixBrcode.valid?("00020126580014br.gov.bcb.pix0136123e4567-e12b-12d1-a456-4266554400005204000053039865802BR5913Fulano de Tal6008BRASILIA62070503***63041D3D")
      true
  """
  def valid?(payload), do: match?({:ok, _}, decode(payload))

  # Key formats from the DICT API spec (github.com/bacen/pix-dict-api, openapi/openapi.yaml):
  # CPF, CNPJ, phone, e-mail (lowercase) and EVP (lowercase UUID). Any key is max 77 chars.
  # \A and \z anchor the whole string; ^ and $ would accept a trailing "\n".
  defp valid_key?(key) do
    String.length(key) <= 77 and
      Enum.any?(
        [
          ~r/\A[0-9]{11}\z/,
          ~r/\A[0-9]{14}\z/,
          ~r/\A\+[1-9][0-9]\d{1,14}\z/,
          ~r"\A[a-z0-9.!#$&'*+/=?^_`{|}~-]+@[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)*\z",
          ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/
        ],
        &(key =~ &1)
      )
  end

  defp check(true, _reason), do: :ok
  defp check(false, reason), do: {:error, reason}

  defp format_amount(nil), do: {:ok, nil}

  defp format_amount(cents) when is_integer(cents) and cents > 0 do
    {units, cents} =
      cents |> Integer.to_string() |> String.pad_leading(3, "0") |> String.split_at(-2)

    format_amount(units <> "." <> cents)
  end

  # Field 54 holds at most 13 characters (BR Code manual).
  defp format_amount(amount) when is_binary(amount) do
    if amount =~ ~r/\A\d+\.\d{2}\z/ and amount =~ ~r/[1-9]/ and byte_size(amount) <= 13,
      do: {:ok, amount},
      else: {:error, :invalid_amount}
  end

  defp format_amount(_amount), do: {:error, :invalid_amount}

  # Strips accents and requires printable ASCII, so the TLV length is the same in
  # characters and bytes for every bank's parser. Returns nil when invalid.
  defp clean(value, max) when is_binary(value) do
    if String.valid?(value) do
      value = strip_accents(value)
      if value =~ ~r/\A[\x20-\x7E]+\z/ and String.length(value) <= max, do: value
    end
  end

  defp clean(_value, _max), do: nil

  # "São João" -> "Sao Joao": NFD splits letter and accent; \p{Mn} matches only the accent.
  defp strip_accents(string) do
    string |> :unicode.characters_to_nfd_binary() |> String.replace(~r/\p{Mn}/u, "")
  end
end
