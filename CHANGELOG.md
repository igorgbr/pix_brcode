# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.2.0] - 2026-10-13

### Added

- `@spec` and `@type` for the whole public API (`t:PixBrcode.params/0`,
  `t:PixBrcode.error/0`, `t:PixBrcode.key_type/0`, ...).
- Formatted keys are accepted and written in the DICT canonical form:
  `"123.456.789-09"` → `"12345678909"`, `"+55 (11) 98765-4321"` → `"+5511987654321"`,
  `" Fulano@Exemplo.com "` → `"fulano@exemplo.com"`, uppercase EVP → lowercase.
- Alphanumeric CNPJ keys (e.g. `"12.ABC.345/01DE-35"` → `"12ABC34501DE35"`).
- `:key_type` option in `encode/1` (`:cpf`, `:cnpj`, `:phone`, `:email`, `:evp`).
  An 11-digit number is read as a CPF; use `key_type: :phone` for a phone without `+55`.
- `{:error, :invalid_key_type}` for an unknown `:key_type`.
- This changelog.

### Changed

- `encode/1` now checks the CPF and CNPJ check digits. Keys such as `"12345678901"`,
  accepted by 0.1.0, now return `{:error, :invalid_key}`.
- `decode/1` returns the key in canonical form and no longer rejects a payload
  because of key formatting. Check digits are not verified when decoding.
- A `+55` phone key needs a DDD and 8 or 9 digits (`"+5511"` is no longer accepted).

### Fixed

- Invalid UTF-8 input made `decode/1`, `valid?/1`, `encode/1` and `encode_dynamic/1`
  raise `ArgumentError`; they now return `{:error, _}`.

## [0.1.0] - 2026-09-26

### Added

- `encode/1`: static payload with key, amount, txid and description.
- `encode_dynamic/1`: dynamic payload with the receiver bank's URL.
- `decode/1` and `valid?/1`, with CRC16, structure, GUI and key format checks.
- Validation of the DICT key formats (CPF, CNPJ, phone, e-mail, EVP).

[0.2.0]: https://github.com/igorgbr/pix_brcode/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/igorgbr/pix_brcode/releases/tag/v0.1.0
