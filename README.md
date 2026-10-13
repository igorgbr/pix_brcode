# PixBrcode

[![CI](https://github.com/igorgbr/pix_brcode/actions/workflows/ci.yml/badge.svg)](https://github.com/igorgbr/pix_brcode/actions/workflows/ci.yml)
[![Hex.pm](https://img.shields.io/hexpm/v/pix_brcode.svg)](https://hex.pm/packages/pix_brcode)
[![Docs](https://img.shields.io/badge/hex-docs-purple.svg)](https://hexdocs.pm/pix_brcode)
[![License](https://img.shields.io/hexpm/l/pix_brcode.svg)](https://github.com/igorgbr/pix_brcode/blob/main/LICENSE)

Generate, parse and validate [Pix](https://www.bcb.gov.br/estabilidadefinanceira/pix)
"copia e cola" payloads (BR Code), the text behind every Pix QR code.

- Static payloads (key, optional amount, txid, description)
- Dynamic payloads (URL provided by the receiver's bank)
- Parsing into a struct, with CRC16 check
- Key validation and normalization (CPF, CNPJ including alphanumeric, phone, e-mail, random key/EVP)
- Zero runtime dependencies

## Installation

```elixir
def deps do
  [
    {:pix_brcode, "~> 0.2.0"}
  ]
end
```

## Usage

### Static payload

```elixir
PixBrcode.encode(%{
  key: "pix@bcb.gov.br",
  merchant_name: "Fulano de Tal",
  merchant_city: "Brasília",
  amount: 1050,        # integer cents, or the string "10.50"
  txid: "ORDER42",     # optional, defaults to "***"
  description: "Thanks" # optional
})
#=> {:ok, "00020126...6304XXXX"}
```

- `merchant_name` (max 25 chars) and `merchant_city` (max 15 chars) have their accents
  removed (`"Brasília"` becomes `"Brasilia"`). Longer values return an error; they are never truncated.
- `amount` never goes through floats: pass integer cents (`1050`) or a string with
  exactly two decimals (`"10.50"`).
- `key` is written in the canonical format of the Central Bank's DICT. Formatted input
  is accepted, so you can pass what the user typed:

  | Type | Input | Written as |
  |---|---|---|
  | CPF | `"123.456.789-09"` | `"12345678909"` |
  | CNPJ | `"11.222.333/0001-81"`, `"12.ABC.345/01DE-35"` | `"11222333000181"`, `"12ABC34501DE35"` |
  | Phone | `"+55 (11) 98765-4321"`, `"(11) 98765-4321"`, `"5511987654321"` | `"+5511987654321"` |
  | E-mail | `" Fulano@Exemplo.com "` | `"fulano@exemplo.com"` |
  | EVP | uppercase UUID | lowercase UUID |

  CPF and CNPJ must have valid check digits. An 11-digit number such as `"11987654321"`
  is read as a CPF; for a phone number without `+55`, pass `key_type: :phone`
  (also `:cpf`, `:cnpj`, `:email`, `:evp`).

### Dynamic payload

```elixir
PixBrcode.encode_dynamic(%{
  url: "pix.example.com/qr/v2/9d36b84f",  # without https://
  merchant_name: "Fulano de Tal",
  merchant_city: "Brasilia"
})
```

### Parsing and validating

```elixir
PixBrcode.decode("00020126580014br.gov.bcb.pix0136123e4567-e12b-12d1-a456-4266554400005204000053039865802BR5913Fulano de Tal6008BRASILIA62070503***63041D3D")
#=> {:ok,
#=>  %PixBrcode.Payload{
#=>    type: :static,
#=>    key: "123e4567-e12b-12d1-a456-426655440000",
#=>    merchant_name: "Fulano de Tal",
#=>    merchant_city: "BRASILIA",
#=>    txid: "***",
#=>    amount: nil, description: nil, url: nil
#=>  }}

PixBrcode.valid?("not a pix")
#=> false
```

`decode/1` checks the CRC, the structure, the `br.gov.bcb.pix` GUI and the key format,
and returns the key in canonical form. Check digits are not verified when decoding, since
the CRC already guarantees the payload is intact. Leading/trailing whitespace is ignored.

### Errors

All functions return `{:ok, result}` or `{:error, reason}`:

| Reason | When |
|---|---|
| `:missing_required_fields` | a required field is missing or is not a string |
| `:invalid_key` | key does not match any DICT format, or CPF/CNPJ has wrong check digits |
| `:invalid_key_type` | `:key_type` is not one of `:cpf`, `:cnpj`, `:phone`, `:email`, `:evp` |
| `:invalid_merchant_name` / `:invalid_merchant_city` | empty, too long, or not printable ASCII after removing accents |
| `:invalid_description` | not a string, or not printable ASCII after removing accents |
| `:invalid_amount` | not positive integer cents nor a `"10.50"` string, or over 13 characters |
| `:invalid_txid` | not `"***"` nor 1–25 letters/digits |
| `:invalid_url` | empty or contains a protocol (`https://`) |
| `{:too_long, id}` | field `id` would exceed 99 characters |
| `:invalid_crc` / `:invalid_tlv` / `:invalid_format` / `:invalid_gui` / `:missing_key` | when decoding |

## QR code image

Generating the image is out of scope, so any QR code library works. With
[`eqrcode`](https://hex.pm/packages/eqrcode):

```elixir
{:ok, payload} = PixBrcode.encode(%{key: "pix@bcb.gov.br", merchant_name: "Fulano", merchant_city: "Brasilia"})

svg = payload |> EQRCode.encode() |> EQRCode.svg()
```

## Specification

Based on the Central Bank of Brazil's *Manual do BR Code* (EMV QRCPS-MPM) and the key formats
of the [DICT API](https://github.com/bacen/pix-dict-api) and the *Manual Operacional do DICT*
(v8.5, alphanumeric CNPJ).

## License

[MIT](https://github.com/igorgbr/pix_brcode/blob/main/LICENSE) — Igor Giamoniano.
