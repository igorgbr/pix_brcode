defmodule PixBrcode do
  @moduledoc """
  Generates and reads Pix "copia e cola" payloads (BR Code).
  """

  alias PixBrcode.{CRC16, Payload, TLV}

  @gui "br.gov.bcb.pix"
  @key_types [:email, :evp, :phone, :cpf, :cnpj]
  @cpf_weights Enum.to_list(11..2//-1)
  @cnpj_weights [6, 5, 4, 3, 2, 9, 8, 7, 6, 5, 4, 3, 2]

  @typedoc "Pix key type, for the `:key_type` option of `encode/1`."
  @type key_type :: :cpf | :cnpj | :phone | :email | :evp

  @typedoc "Parameters of `encode/1`."
  @type params :: %{
          required(:key) => String.t(),
          required(:merchant_name) => String.t(),
          required(:merchant_city) => String.t(),
          optional(:key_type) => key_type(),
          optional(:amount) => pos_integer() | String.t(),
          optional(:txid) => String.t(),
          optional(:description) => String.t()
        }

  @typedoc "Parameters of `encode_dynamic/1`."
  @type dynamic_params :: %{
          required(:url) => String.t(),
          required(:merchant_name) => String.t(),
          required(:merchant_city) => String.t()
        }

  @typedoc "Reason returned in `{:error, reason}`."
  @type error ::
          :missing_required_fields
          | :invalid_key
          | :invalid_key_type
          | :invalid_merchant_name
          | :invalid_merchant_city
          | :invalid_description
          | :invalid_amount
          | :invalid_txid
          | :invalid_url
          | {:too_long, String.t()}
          | :invalid_crc
          | :invalid_tlv
          | :invalid_format
          | :invalid_gui
          | :missing_key

  @doc """
  Builds a static Pix payload.

  Required: `:key`, `:merchant_name` (max 25 chars), `:merchant_city` (max 15 chars).
  Optional: `:amount` (`"10.50"` or integer cents `1050`), `:txid` (default `"***"`),
  `:description`, `:key_type`. Accents in name and city are removed.

  The key may come formatted (`"123.456.789-09"`, `"+55 (11) 98765-4321"`,
  `" Fulano@Exemplo.com "`) and is written in the DICT canonical form. CPF and CNPJ
  (numeric or alphanumeric) must have valid check digits. An 11-digit number is read
  as a CPF; pass `key_type: :phone` for a phone number without `+55`.

      iex> PixBrcode.encode(%{key: "123e4567-e12b-12d1-a456-426655440000",
      ...>   merchant_name: "Fulano de Tal", merchant_city: "BRASILIA"})
      {:ok, "00020126580014br.gov.bcb.pix0136123e4567-e12b-12d1-a456-4266554400005204000053039865802BR5913Fulano de Tal6008BRASILIA62070503***63041D3D"}
  """
  @spec encode(params()) :: {:ok, String.t()} | {:error, error()}
  def encode(%{key: key, merchant_name: name, merchant_city: city} = params)
      when is_binary(key) and is_binary(name) and is_binary(city) do
    txid = Map.get(params, :txid) || "***"
    description = Map.get(params, :description)
    key_type = Map.get(params, :key_type)

    with :ok <- check(key_type in [nil | @key_types], :invalid_key_type),
         {:ok, key} <- encode_key(key, key_type),
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
  @spec encode_dynamic(dynamic_params()) :: {:ok, String.t()} | {:error, error()}
  def encode_dynamic(%{url: url, merchant_name: name, merchant_city: city} = params)
      when is_binary(url) and is_binary(name) and is_binary(city) do
    with :ok <-
           check(
             String.valid?(url) and url != "" and not String.contains?(url, "://"),
             :invalid_url
           ) do
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

  The key is returned in the DICT canonical form, the same way `encode/1` writes it
  (`"123.456.789-09"` becomes `"12345678909"`). Check digits are not verified here:
  the CRC already guarantees the payload was not corrupted.

      iex> {:ok, payload} = PixBrcode.decode("00020126580014br.gov.bcb.pix0136123e4567-e12b-12d1-a456-4266554400005204000053039865802BR5913Fulano de Tal6008BRASILIA62070503***63041D3D")
      iex> {payload.type, payload.key, payload.merchant_name}
      {:static, "123e4567-e12b-12d1-a456-426655440000", "Fulano de Tal"}
  """
  @spec decode(term()) :: {:ok, Payload.t()} | {:error, error()}
  def decode(payload) when is_binary(payload) do
    # String functions raise on some invalid UTF-8 sequences; a valid payload is ASCII anyway.
    if String.valid?(payload),
      do: do_decode(String.trim(payload)),
      else: {:error, :invalid_format}
  end

  def decode(_payload), do: {:error, :invalid_format}

  defp do_decode(payload) do
    {data, crc} = String.split_at(payload, -4)

    with :ok <-
           check(
             String.ends_with?(data, "6304") and
               String.upcase(crc, :ascii) == CRC16.checksum(data),
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
         :ok <- check(String.downcase(account["00"] || "", :ascii) == @gui, :invalid_gui),
         :ok <- check(Map.has_key?(account, "01") or Map.has_key?(account, "25"), :missing_key),
         {:ok, key} <- decode_key(account["01"]),
         {:ok, additional} <- TLV.decode(Map.get(fields, "62", "")) do
      {:ok,
       %Payload{
         type: if(Map.has_key?(account, "25"), do: :dynamic, else: :static),
         key: key,
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
  @spec valid?(term()) :: boolean()
  def valid?(payload), do: match?({:ok, _}, decode(payload))

  # Strict on what we generate: CPF and CNPJ also need valid check digits.
  defp encode_key(key, type) do
    case canonical_key(key, type) do
      {:cpf, key} -> check_digits(key, @cpf_weights)
      {:cnpj, key} -> check_digits(key, @cnpj_weights)
      {_type, key} -> {:ok, key}
      nil -> {:error, :invalid_key}
    end
  end

  # Tolerant on what we read: same normalization, no check digits (the CRC covers integrity).
  defp decode_key(nil), do: {:ok, nil}

  defp decode_key(key) do
    case canonical_key(key, nil) do
      {_type, key} -> {:ok, key}
      nil -> {:error, :invalid_key}
    end
  end

  # Returns {type, key} with the key in the DICT canonical form, or nil.
  # Without a type, the first format that matches wins (order of @key_types).
  # Invalid UTF-8 is rejected first: String functions raise on some broken sequences.
  defp canonical_key(key, type) do
    cond do
      not String.valid?(key) -> nil
      type -> canonical_key(String.trim(key), type, true)
      true -> Enum.find_value(@key_types, &canonical_key(String.trim(key), &1, false))
    end
  end

  # Formats from the DICT API spec (github.com/bacen/pix-dict-api, openapi/openapi.yaml)
  # and the DICT operational manual v8.5 (alphanumeric CNPJ). Only each type's usual
  # punctuation is removed; anything else keeps the key invalid.
  # \A and \z anchor the whole string; ^ and $ would accept a trailing "\n".
  # Case changes are ASCII-only: Unicode rules turn U+212A (Kelvin sign) into "k" and "ß" into "SS",
  # which would make garbage input a different, valid key.
  defp canonical_key(key, :email, _explicit) do
    key = String.downcase(key, :ascii)

    if String.length(key) <= 77 and
         key =~
           ~r"\A[a-z0-9.!#$&'*+/=?^_`{|}~-]+@[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)*\z",
       do: {:email, key}
  end

  defp canonical_key(key, :evp, _explicit) do
    key = String.downcase(key, :ascii)

    if key =~ ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/,
      do: {:evp, key}
  end

  # "11987654321" is also a valid CPF, so without an explicit type a phone needs a hint:
  # "+", parentheses, or 13 digits starting with 55.
  defp canonical_key(key, :phone, explicit) do
    digits = String.replace(key, ~r/[ ()-]/, "")

    phone =
      cond do
        String.starts_with?(digits, "+") -> digits
        digits =~ ~r/\A55\d{11}\z/ -> "+" <> digits
        digits =~ ~r/\A\d{11}\z/ and (explicit or String.contains?(key, "(")) -> "+55" <> digits
        true -> nil
      end

    if phone && valid_phone?(phone), do: {:phone, phone}
  end

  defp canonical_key(key, :cpf, _explicit) do
    key = String.replace(key, ~r/[. -]/, "")
    if key =~ ~r/\A\d{11}\z/, do: {:cpf, key}
  end

  # Alphanumeric CNPJ (Receita, from July 2026): 12 characters [0-9A-Z] + 2 numeric check digits.
  defp canonical_key(key, :cnpj, _explicit) do
    key = key |> String.replace(~r"[./ -]", "") |> String.upcase(:ascii)
    if key =~ ~r/\A[0-9A-Z]{12}\d{2}\z/, do: {:cnpj, key}
  end

  # E.164, as in the DICT. A Brazilian number (+55) also needs DDD + 8 or 9 digits,
  # so "+55(11)" does not become the key "+5511".
  defp valid_phone?("+55" <> number), do: number =~ ~r/\A\d{10,11}\z/
  defp valid_phone?(phone), do: phone =~ ~r/\A\+[1-9][0-9]\d{1,14}\z/

  # Mod 11 check digits. Each character is worth its ASCII code minus 48, so digits keep
  # their value and the CNPJ letters go A=17, B=18... (Receita's alphanumeric CNPJ rule).
  defp check_digits(key, weights) do
    chars = String.to_charlist(key)
    body = Enum.drop(chars, -2)
    dv1 = check_digit(body, weights)

    # "00000000000" and friends pass the arithmetic but are not real documents.
    if length(Enum.uniq(chars)) > 1 and
         chars == body ++ [dv1, check_digit(body ++ [dv1], weights)],
       do: {:ok, key},
       else: {:error, :invalid_key}
  end

  # Uses the last length(chars) weights: CPF 10..2 then 11..2, CNPJ 5,4,3,2,9.. then 6,5,4..
  defp check_digit(chars, weights) do
    sum =
      chars
      |> Enum.zip(Enum.take(weights, -length(chars)))
      |> Enum.reduce(0, fn {char, weight}, acc -> acc + (char - ?0) * weight end)

    case rem(sum, 11) do
      rest when rest < 2 -> ?0
      rest -> ?0 + 11 - rest
    end
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
