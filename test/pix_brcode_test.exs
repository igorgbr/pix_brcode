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

    test "rejects invalid input without raising" do
      assert PixBrcode.encode(Map.put(@base, :amount, "12345678901234.00")) ==
               {:error, :invalid_amount}

      assert PixBrcode.encode(Map.put(@base, :merchant_name, <<0xFF>>)) ==
               {:error, :invalid_merchant_name}

      assert PixBrcode.encode(Map.put(@base, :merchant_name, "Café ☕")) ==
               {:error, :invalid_merchant_name}

      assert PixBrcode.encode(Map.put(@base, :description, 42)) == {:error, :invalid_description}
      assert PixBrcode.decode(nil) == {:error, :invalid_format}
      refute PixBrcode.valid?(nil)
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
      assert PixBrcode.encode(Map.put(@base, :amount, "10.50\n")) == {:error, :invalid_amount}
      assert PixBrcode.encode(Map.put(@base, :txid, "ABC\n")) == {:error, :invalid_txid}

      assert PixBrcode.encode(Map.put(@base, :description, String.duplicate("a", 80))) ==
               {:error, {:too_long, "26"}}
    end

    test "strips accents from description" do
      {:ok, payload} = PixBrcode.encode(Map.put(@base, :description, "Pagamento café"))
      assert {:ok, %{description: "Pagamento cafe"}} = PixBrcode.decode(payload)
    end

    test "rejects zero amount as string" do
      assert PixBrcode.encode(Map.put(@base, :amount, "0.00")) == {:error, :invalid_amount}
    end
  end

  describe "key validation" do
    # Fictitious documents with valid check digits. 12ABC34501DE35 is the Receita's own
    # alphanumeric CNPJ example.
    @valid_keys [
      "12345678909",
      "11222333000181",
      "12ABC34501DE35",
      "+5561998765432",
      "pix@bcb.gov.br",
      "123e4567-e89b-12d3-a456-426655440000"
    ]

    # {input, canonical key}
    @formatted_keys [
      {"123.456.789-09", "12345678909"},
      {"123 456 789 09", "12345678909"},
      {" 12345678909\n", "12345678909"},
      {"11.222.333/0001-81", "11222333000181"},
      {"12.abc.345/01de-35", "12ABC34501DE35"},
      {"+55 (11) 98765-4321", "+5511987654321"},
      {"(11) 98765-4321", "+5511987654321"},
      {"5511987654321", "+5511987654321"},
      {"+1 415 555 2671", "+14155552671"},
      {"  Fulano@Exemplo.com ", "fulano@exemplo.com"},
      {"123E4567-E89B-12D3-A456-426655440000", "123e4567-e89b-12d3-a456-426655440000"}
    ]

    @invalid_keys [
      "",
      "12345678901",
      "00000000000",
      "123.456.789_09",
      "12345678901234",
      "12.ABC.345/01DE-34",
      "12ABC34501DEAB",
      "1234567890",
      "+0061998765432",
      "+55(11)",
      "pix@",
      String.duplicate("a", 70) <> "@bcb.gov.br",
      # Unicode case mapping must not turn these into other, valid keys.
      "\u212Aey@exemplo.com",
      "12\u00DFC34501DE33",
      "12\uFB01C34501DE70",
      # Invalid UTF-8
      <<0xE2, 0x9B, 0x85, 0x96>>
    ]

    test "encode/1 accepts the DICT key formats" do
      for key <- @valid_keys do
        assert {:ok, payload} = PixBrcode.encode(%{@base | key: key}), key
        assert {:ok, %{key: ^key}} = PixBrcode.decode(payload)
      end
    end

    test "encode/1 normalizes formatted keys to the DICT canonical form" do
      for {input, key} <- @formatted_keys do
        assert {:ok, payload} = PixBrcode.encode(%{@base | key: input}), inspect(input)
        assert {:ok, %{key: ^key}} = PixBrcode.decode(payload)
      end
    end

    test "encode/1 rejects malformed keys and wrong check digits" do
      for key <- @invalid_keys do
        assert PixBrcode.encode(%{@base | key: key}) == {:error, :invalid_key}, inspect(key)
      end
    end

    test "an 11-digit number is a CPF unless key_type says otherwise" do
      assert PixBrcode.encode(%{@base | key: "11987654321"}) == {:error, :invalid_key}

      assert {:ok, payload} =
               PixBrcode.encode(Map.merge(@base, %{key: "11987654321", key_type: :phone}))

      assert {:ok, %{key: "+5511987654321"}} = PixBrcode.decode(payload)

      assert PixBrcode.encode(Map.merge(@base, %{key: "pix@bcb.gov.br", key_type: :cpf})) ==
               {:error, :invalid_key}

      assert PixBrcode.encode(Map.merge(@base, %{key: "x", key_type: :telefone})) ==
               {:error, :invalid_key_type}
    end

    test "key_type accepts every DICT type" do
      for {key, type, canonical} <- [
            {"123.456.789-09", :cpf, "12345678909"},
            {"12.abc.345/01de-35", :cnpj, "12ABC34501DE35"},
            {" Pix@BCB.gov.br", :email, "pix@bcb.gov.br"},
            {"123E4567-E89B-12D3-A456-426655440000", :evp, "123e4567-e89b-12d3-a456-426655440000"}
          ] do
        assert {:ok, payload} = PixBrcode.encode(Map.merge(@base, %{key: key, key_type: type}))
        assert {:ok, %{key: ^canonical}} = PixBrcode.decode(payload)
      end
    end

    test "invalid UTF-8 returns an error instead of raising" do
      bad = <<0xE2, 0x9B, 0x85, 0x96>>
      assert PixBrcode.decode(bad <> "6304ABCD") == {:error, :invalid_format}
      refute PixBrcode.valid?(bad)

      assert PixBrcode.encode_dynamic(%{url: bad, merchant_name: "F", merchant_city: "SP"}) ==
               {:error, :invalid_url}
    end

    test "decode/1 normalizes the key but does not check its digits" do
      {:ok, account} =
        PixBrcode.TLV.encode([{"00", "br.gov.bcb.pix"}, {"01", "123.456.789-01"}])

      assert {:ok, %{key: "12345678901"}} = PixBrcode.decode(build([{"26", account}]))
    end
  end

  describe "decode/1" do
    # Builds a payload with a valid CRC from a list of top-level fields.
    defp build(fields) do
      {:ok, data} = PixBrcode.TLV.encode([{"00", "01"} | fields])
      data = data <> "6304"
      data <> PixBrcode.CRC16.checksum(data)
    end

    # Same layout as real payloads generated by the banks' apps (Sep 2026), with fictitious data.
    test "reads bank-style payloads (uppercase GUI, postal code)" do
      nubank =
        "00020126580014BR.GOV.BCB.PIX0136123e4567-e89b-12d3-a456-42661417400052040000530398654040.015802BR592412.345.678 FULANO DE TAL6009SAO PAULO61080100100062250521AB12cDEFgHiJklmNOp3qr63046B57"

      itau =
        "00020126580014BR.GOV.BCB.PIX0136123e4567-e89b-12d3-a456-42661417400152040000530398654040.015802BR5913FULANO DE TAL6009SAO PAULO6226052211a2BCDEfghI3J4K5lmNop6304FE55"

      assert {:ok, %{key: "123e4567-e89b-12d3-a456-426614174000", amount: "0.01"}} =
               PixBrcode.decode(nubank)

      assert {:ok, %{merchant_name: "FULANO DE TAL", txid: "11a2BCDEfghI3J4K5lmNop"}} =
               PixBrcode.decode(itau)
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

  describe "encode_dynamic/1" do
    @dynamic %{
      url: "pix.example.com/qr/v2/abc",
      merchant_name: "Fulano",
      merchant_city: "Sao Paulo"
    }

    test "round trip with decode/1" do
      {:ok, payload} = PixBrcode.encode_dynamic(@dynamic)

      assert PixBrcode.decode(payload) ==
               {:ok,
                %PixBrcode.Payload{
                  type: :dynamic,
                  url: "pix.example.com/qr/v2/abc",
                  merchant_name: "Fulano",
                  merchant_city: "Sao Paulo",
                  txid: "***"
                }}
    end

    test "errors" do
      assert PixBrcode.encode_dynamic(%{@dynamic | url: "https://pix.example.com/qr"}) ==
               {:error, :invalid_url}

      assert PixBrcode.encode_dynamic(%{@dynamic | url: ""}) == {:error, :invalid_url}

      assert PixBrcode.encode_dynamic(%{@dynamic | url: String.duplicate("a", 78)}) ==
               {:error, {:too_long, "26"}}

      assert PixBrcode.encode_dynamic(%{url: "x"}) == {:error, :missing_required_fields}
    end
  end
end
