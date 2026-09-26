defmodule PixBrcode.CRC16 do
  @moduledoc false
  # CRC16/CCITT-FALSE: poly 0x1021, init 0xFFFF, no reflection, no final XOR.

  import Bitwise

  @doc "Returns the CRC of `data` as 4 uppercase hex digits."
  def checksum(data) when is_binary(data) do
    data
    |> crc(0xFFFF)
    |> Integer.to_string(16)
    |> String.pad_leading(4, "0")
  end

  defp crc(<<byte, rest::binary>>, acc) do
    acc = Enum.reduce(1..8, bxor(acc, byte <<< 8), fn _, acc -> shift(acc <<< 1) end)
    crc(rest, acc)
  end

  defp crc(<<>>, acc), do: acc

  # If the bit shifted out (bit 16) was 1, apply the polynomial; always keep 16 bits.
  defp shift(acc) when acc > 0xFFFF, do: bxor(acc, 0x1021) &&& 0xFFFF
  defp shift(acc), do: acc
end
