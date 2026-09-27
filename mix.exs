defmodule PixBrcode.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/igorgbr/pix_brcode"

  def project do
    [
      app: :pix_brcode,
      version: @version,
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: "Generate, parse and validate Pix \"copia e cola\" payloads (BR Code).",
      package: [
        licenses: ["MIT"],
        links: %{"GitHub" => @source_url}
      ],
      source_url: @source_url,
      docs: [main: "readme", extras: ["README.md"], source_ref: "v#{@version}"]
    ]
  end

  def application do
    []
  end

  defp deps do
    [
      {:ex_doc, "~> 0.40", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
    ]
  end
end
