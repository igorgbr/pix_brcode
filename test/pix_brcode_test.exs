defmodule PixBrcodeTest do
  use ExUnit.Case
  doctest PixBrcode

  # Example from the BR Code manual (Banco Central do Brasil). The CRC covers everything up to and including "6304".
  @example "00020126580014br.gov.bcb.pix0136123e4567-e12b-12d1-a456-4266554400005204000053039865802BR5913Fulano de Tal6008BRASILIA62070503***63041D3D"

  test "CRC16 of the manual example" do
    {without_crc, "1D3D"} = String.split_at(@example, -4)
    assert PixBrcode.CRC16.checksum(without_crc) == "1D3D"
  end

  describe "TLV" do
    alias PixBrcode.TLV

    test "decode and encode the manual example (round trip)" do
      {:ok, fields} = TLV.decode(@example)
      assert List.first(fields) == {"00", "01"}
      assert List.last(fields) == {"63", "1D3D"}

      {"26", account} = List.keyfind(fields, "26", 0)

      assert TLV.decode(account) ==
               {:ok, [{"00", "br.gov.bcb.pix"}, {"01", "123e4567-e12b-12d1-a456-426655440000"}]}

      assert TLV.encode(fields) == {:ok, @example}
    end

    test "encode skips empty fields and rejects values over 99 characters" do
      assert TLV.encode([{"00", "01"}, {"54", nil}, {"58", "BR"}]) == {:ok, "0002015802BR"}
      assert TLV.encode([{"59", String.duplicate("a", 100)}]) == {:error, {:too_long, "59"}}
    end

    test "decode rejects truncated input and non-numeric lengths" do
      assert TLV.decode("000201580") == {:error, :invalid_tlv}
      assert TLV.decode("0002015805BR") == {:error, :invalid_tlv}
      assert TLV.decode("00AB01") == {:error, :invalid_tlv}
    end
  end

  describe "encode/1" do
    @base %{key: "key@example.com", merchant_name: "Fulano", merchant_city: "Sao Paulo"}

    test "amount as integer cents and as string build the same payload" do
      {:ok, payload} = PixBrcode.encode(Map.put(@base, :amount, 1050))
      assert payload =~ "540510.50"
      assert PixBrcode.encode(Map.put(@base, :amount, "10.50")) == {:ok, payload}
      assert PixBrcode.encode(Map.put(@base, :amount, 5)) |> elem(1) =~ "54040.05"
    end

    test "strips accents from name and city" do
      {:ok, payload} =
        PixBrcode.encode(%{@base | merchant_name: "João", merchant_city: "São Paulo"})

      assert payload =~ "5904Joao6009Sao Paulo"
    end

    test "validation errors" do
      assert PixBrcode.encode(%{key: "x"}) == {:error, :missing_required_fields}
      assert PixBrcode.encode(%{@base | key: ""}) == {:error, :invalid_key}

      assert PixBrcode.encode(%{@base | merchant_name: String.duplicate("a", 26)}) ==
               {:error, :invalid_merchant_name}

      assert PixBrcode.encode(%{@base | merchant_city: String.duplicate("a", 16)}) ==
               {:error, :invalid_merchant_city}

      assert PixBrcode.encode(Map.put(@base, :txid, "com espaco")) == {:error, :invalid_txid}
      assert PixBrcode.encode(Map.put(@base, :amount, "10,50")) == {:error, :invalid_amount}
      assert PixBrcode.encode(Map.put(@base, :amount, 0)) == {:error, :invalid_amount}

      assert PixBrcode.encode(Map.put(@base, :description, String.duplicate("a", 80))) ==
               {:error, {:too_long, "26"}}
    end
  end

  describe "key validation" do
    @valid_keys [
      "12345678901",
      "12345678901234",
      "+5561998765432",
      "pix@bcb.gov.br",
      "123e4567-e89b-12d3-a456-426655440000"
    ]

    @invalid_keys [
      "",
      "123.456.789-01",
      "1234567890",
      "+0061998765432",
      "Pix@BCB.gov.br",
      "pix@",
      "123E4567-E89B-12D3-A456-426655440000",
      "12345678901\n",
      String.duplicate("a", 70) <> "@bcb.gov.br"
    ]

    test "encode/1 accepts the DICT key formats" do
      for key <- @valid_keys do
        assert {:ok, payload} = PixBrcode.encode(%{@base | key: key}), key
        assert {:ok, %{key: ^key}} = PixBrcode.decode(payload)
      end
    end

    test "encode/1 rejects malformed keys" do
      for key <- @invalid_keys do
        assert PixBrcode.encode(%{@base | key: key}) == {:error, :invalid_key}, inspect(key)
      end
    end
  end

  describe "decode/1" do
    # Builds a payload with a valid CRC from a list of top-level fields.
    defp build(fields) do
      {:ok, data} = PixBrcode.TLV.encode([{"00", "01"} | fields])
      data = data <> "6304"
      data <> PixBrcode.CRC16.checksum(data)
    end

    test "round trip with encode/1" do
      params = %{
        key: "key@example.com",
        merchant_name: "Fulano",
        merchant_city: "Sao Paulo",
        amount: 1050,
        txid: "ABC123",
        description: "Order 42"
      }

      {:ok, payload} = PixBrcode.encode(params)

      assert PixBrcode.decode(payload) ==
               {:ok,
                %PixBrcode.Payload{
                  type: :static,
                  key: "key@example.com",
                  description: "Order 42",
                  amount: "10.50",
                  merchant_name: "Fulano",
                  merchant_city: "Sao Paulo",
                  txid: "ABC123"
                }}
    end

    test "accepts surrounding whitespace and lowercase CRC" do
      assert PixBrcode.valid?("  " <> String.replace(@example, "1D3D", "1d3d") <> "\n")
    end

    test "dynamic payload" do
      {:ok, account} =
        PixBrcode.TLV.encode([{"00", "br.gov.bcb.pix"}, {"25", "pix.example.com/qr/v2/abc"}])

      assert {:ok, %{type: :dynamic, url: "pix.example.com/qr/v2/abc", key: nil}} =
               PixBrcode.decode(build([{"26", account}, {"59", "Fulano"}]))
    end

    test "errors" do
      assert PixBrcode.decode(String.replace(@example, "1D3D", "1D3E")) == {:error, :invalid_crc}
      assert PixBrcode.decode("") == {:error, :invalid_crc}
      assert PixBrcode.decode(build([{"26", "0014br.gov.bcb.pi"}])) == {:error, :invalid_tlv}

      {:ok, wrong_gui} = PixBrcode.TLV.encode([{"00", "br.gov.bcb.xyz"}, {"01", "k"}])
      assert PixBrcode.decode(build([{"26", wrong_gui}])) == {:error, :invalid_gui}

      {:ok, bad_key} = PixBrcode.TLV.encode([{"00", "br.gov.bcb.pix"}, {"01", "not a key"}])
      assert PixBrcode.decode(build([{"26", bad_key}])) == {:error, :invalid_key}

      {:ok, no_key} = PixBrcode.TLV.encode([{"00", "br.gov.bcb.pix"}])
      assert PixBrcode.decode(build([{"26", no_key}])) == {:error, :missing_key}
      refute PixBrcode.valid?("hello")
    end
  end
end
