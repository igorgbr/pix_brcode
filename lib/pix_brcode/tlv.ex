defmodule PixBrcode.TLV do
  @moduledoc false
  # EMV format: ID (2 digits) + length (2 digits) + value.
  # Length is counted in characters, max 99.

  defguardp is_digit(c) when c in ?0..?9

  @doc """
  Joins `[{"00", "01"}, {"59", "Fulano"}]` into `"000201" <> "5906Fulano"`.
  Fields whose value is `nil` or `""` are skipped (optional fields).
  """
  def encode(fields) do
    fields = Enum.reject(fields, fn {_id, value} -> value in [nil, ""] end)

    case Enum.find(fields, fn {_id, value} -> String.length(value) > 99 end) do
      nil -> {:ok, Enum.map_join(fields, fn {id, value} -> id <> size(value) <> value end)}
      {id, _value} -> {:error, {:too_long, id}}
    end
  end

  defp size(value),
    do: value |> String.length() |> Integer.to_string() |> String.pad_leading(2, "0")

  @doc "Splits the string into `[{id, value}]`, keeping the original order."
  def decode(string) when is_binary(string), do: decode(string, [])

  defp decode("", acc), do: {:ok, Enum.reverse(acc)}

  defp decode(<<i1, i2, l1, l2, rest::binary>>, acc)
       when is_digit(i1) and is_digit(i2) and is_digit(l1) and is_digit(l2) do
    size = (l1 - ?0) * 10 + (l2 - ?0)
    {value, rest} = String.split_at(rest, size)

    if String.length(value) == size do
      decode(rest, [{<<i1, i2>>, value} | acc])
    else
      {:error, :invalid_tlv}
    end
  end

  defp decode(_invalid, _acc), do: {:error, :invalid_tlv}
end
