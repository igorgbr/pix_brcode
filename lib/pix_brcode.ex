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
    name = strip_accents(name)
    city = strip_accents(city)
    txid = Map.get(params, :txid) || "***"

    with :ok <- check(key != "", :invalid_key),
         :ok <- check(String.length(name) in 1..25, :invalid_merchant_name),
         :ok <- check(String.length(city) in 1..15, :invalid_merchant_city),
         :ok <- check(txid == "***" or txid =~ ~r/^[A-Za-z0-9]{1,25}$/, :invalid_txid),
         {:ok, amount} <- format_amount(Map.get(params, :amount)),
         {:ok, account} <-
           TLV.encode([{"00", @gui}, {"01", key}, {"02", Map.get(params, :description)}]),
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

  def encode(_params), do: {:error, :missing_required_fields}

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
         :ok <- check(account["00"] == @gui, :invalid_gui),
         :ok <- check(Map.has_key?(account, "01") or Map.has_key?(account, "25"), :missing_key),
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

  @doc """
  Returns `true` if `payload` decodes successfully.

      iex> PixBrcode.valid?("00020126580014br.gov.bcb.pix0136123e4567-e12b-12d1-a456-4266554400005204000053039865802BR5913Fulano de Tal6008BRASILIA62070503***63041D3D")
      true
  """
  def valid?(payload), do: match?({:ok, _}, decode(payload))

  defp check(true, _reason), do: :ok
  defp check(false, reason), do: {:error, reason}

  defp format_amount(nil), do: {:ok, nil}

  defp format_amount(cents) when is_integer(cents) and cents > 0 do
    {units, cents} =
      cents |> Integer.to_string() |> String.pad_leading(3, "0") |> String.split_at(-2)

    {:ok, units <> "." <> cents}
  end

  defp format_amount(amount) when is_binary(amount) do
    if amount =~ ~r/^\d+\.\d{2}$/, do: {:ok, amount}, else: {:error, :invalid_amount}
  end

  defp format_amount(_amount), do: {:error, :invalid_amount}

  # "São João" -> "Sao Joao": NFD splits letter and accent; \p{Mn} matches only the accent.
  defp strip_accents(string) do
    string |> :unicode.characters_to_nfd_binary() |> String.replace(~r/\p{Mn}/u, "")
  end
end
