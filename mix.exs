defmodule Jido.Shell.MixProject do
  use Mix.Project

  @version "3.0.0"
  @source_url "https://github.com/agentjido/jido_shell"
  @description "Virtual workspace shell for LLM-human collaboration in the AgentJido ecosystem"

  def project do
    [
      app: :jido_shell,
      version: @version,
      elixir: "~> 1.17",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),

      # Test Coverage
      test_coverage: [
        tool: ExCoveralls,
        summary: [threshold: 90],
        coverage_options: [minimum_coverage: 90]
      ],

      # Dialyzer
      dialyzer: [
        plt_local_path: "priv/plts/project.plt",
        plt_core_path: "priv/plts/core.plt",
        flags: [:error_handling, :unknown],
        ignore_warnings: ".dialyzer_ignore.exs"
      ],

      # Package
      package: package(),

      # Documentation
      name: "Jido.Shell",
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
        "coveralls.detail": :test,
        "coveralls.github": :test,
        "coveralls.html": :test,
        "coveralls.json": :test
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {Jido.Shell.Application, []}
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
      {:jido_vfs, github: "agentjido/hako"},
      {:sprites, git: "https://github.com/superfly/sprites-ex.git", optional: true},

      # Dev/Test dependencies
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:excoveralls, "~> 0.18", only: [:dev, :test]},
      {:git_hooks, "~> 0.8", only: [:dev, :test], runtime: false},
      {:git_ops, "~> 2.9", only: :dev, runtime: false},
      {:mimic, "~> 2.0", only: :test},
      {:stream_data, "~> 1.0", only: [:dev, :test]},

      # Code generation
      {:igniter, "~> 0.7", optional: true}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get", "git_hooks.install"],
      test: "test --exclude flaky",
      q: ["quality"],
      quality: [
        "jido_shell.guardrails",
        "format --check-formatted",
        "compile --warnings-as-errors",
        "credo --min-priority higher",
        "dialyzer"
      ]
    ]
  end

  defp package do
    [
      files:
        ~w(lib mix.exs LICENSE README.md MIGRATION.md CHANGELOG.md CONTRIBUTING.md GUARDRAILS.md AGENTS.md usage-rules.md .formatter.exs),
      maintainers: ["Mike Hostetler"],
      licenses: ["Apache-2.0"],
      links: %{
        "Changelog" => "https://hexdocs.pm/jido_shell/changelog.html",
        "Discord" => "https://agentjido.xyz/discord",
        "Documentation" => "https://hexdocs.pm/jido_shell",
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
        "MIGRATION.md",
        "CHANGELOG.md",
        "CONTRIBUTING.md",
        "GUARDRAILS.md",
        "LICENSE"
      ],
      groups_for_modules: [
        Core: [
          Jido.Shell,
          Jido.Shell.Agent,
          Jido.Shell.Backend,
          Jido.Shell.ShellSession,
          Jido.Shell.ShellSessionServer,
          Jido.Shell.ShellSession.State,
          Jido.Shell.Error
        ],
        Deprecated: [
          Jido.Shell.Session,
          Jido.Shell.SessionServer,
          Jido.Shell.Session.State
        ],
        Backends: [
          Jido.Shell.Backend.Local,
          Jido.Shell.Backend.Sprite
        ],
        Commands: ~r/Jido\.Shell\.Command.*/,
        "Virtual Filesystem": [
          Jido.Shell.VFS,
          Jido.Shell.VFS.MountTable
        ],
        Transports: [
          Jido.Shell.Transport.IEx
        ],
        Internals: [
          Jido.Shell.CommandRunner,
          Jido.Shell.Application
        ]
      ]
    ]
  end
end
