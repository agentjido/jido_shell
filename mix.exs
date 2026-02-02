defmodule Kodo.MixProject do
  use Mix.Project

  @version "3.0.0"
  @source_url "https://github.com/agentjido/kodo"
  @description "Virtual workspace shell for LLM-human collaboration in the AgentJido ecosystem"

  def project do
    [
      app: :kodo,
      version: @version,
      elixir: "~> 1.17",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),

      # Test Coverage
      test_coverage: [
        tool: ExCoveralls,
        summary: [threshold: 90]
      ],

      # Dialyzer
      dialyzer: [
        plt_local_path: "priv/plts/project.plt",
        plt_core_path: "priv/plts/core.plt",
        plt_add_apps: [:mix],
        flags: [:error_handling, :unknown]
      ],

      # Package
      package: package(),

      # Documentation
      name: "Kodo",
      description: @description,
      source_url: @source_url,
      homepage_url: @source_url,
      source_ref: "v#{@version}",
      docs: docs()
    ]
  end

  def cli do
    [
      preferred_envs: [
        coveralls: :test,
        "coveralls.github": :test,
        "coveralls.html": :test
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {Kodo.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # Runtime dependencies
      {:jason, "~> 1.4"},
      {:uniq, "~> 0.6"},
      {:zoi, "~> 0.14"},
      {:hako, github: "agentjido/hako"},
      {:term_ui, "~> 0.2.0"},

      # Dev/Test dependencies
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:excoveralls, "~> 0.18", only: [:dev, :test]},
      {:git_hooks, "~> 0.8", only: [:dev, :test], runtime: false},
      {:git_ops, "~> 2.9", only: :dev, runtime: false},
      {:mimic, "~> 2.0", only: :test},
      {:stream_data, "~> 1.0", only: [:dev, :test]}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get", "git_hooks.install"],
      test: "test --exclude flaky",
      q: ["quality"],
      quality: [
        "format --check-formatted",
        "compile --warnings-as-errors",
        "credo --min-priority higher",
        "dialyzer"
      ]
    ]
  end

  defp package do
    [
      files: ~w(lib mix.exs LICENSE README.md CHANGELOG.md CONTRIBUTING.md AGENTS.md usage-rules.md .formatter.exs),
      maintainers: ["Mike Hostetler"],
      licenses: ["Apache-2.0"],
      links: %{
        "Changelog" => "https://hexdocs.pm/kodo/changelog.html",
        "Discord" => "https://agentjido.xyz/discord",
        "Documentation" => "https://hexdocs.pm/kodo",
        "GitHub" => @source_url,
        "Website" => "https://agentjido.xyz"
      }
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      extras: [
        {"README.md", title: "Overview"},
        "CHANGELOG.md",
        "CONTRIBUTING.md"
      ],
      groups_for_modules: [
        Core: [
          Kodo,
          Kodo.Agent,
          Kodo.Session,
          Kodo.SessionServer,
          Kodo.Session.State,
          Kodo.Error
        ],
        Commands: ~r/Kodo\.Command.*/,
        "Virtual Filesystem": [
          Kodo.VFS,
          Kodo.VFS.MountTable
        ],
        Transports: [
          Kodo.Transport.IEx,
          Kodo.Transport.TermUI
        ],
        Internals: [
          Kodo.CommandRunner,
          Kodo.Application
        ]
      ]
    ]
  end
end
