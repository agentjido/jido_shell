defmodule Jido.Shell do
  @moduledoc """
  Jido.Shell v3: Virtual workspace shell for LLM-human collaboration.

  Jido.Shell provides a virtual shell environment embedded in the BEAM, designed as a
  shared workspace for humans and LLM agents using familiar shell semantics.

  ## Key Features

  - **Virtual by default** — In-memory VFS as primary mode
  - **Shared state** — Multiple accessors see and manipulate the same VFS
  - **Familiar interface** — Reuse LLMs' bash training with familiar commands
  - **Predictable** — Small API, synchronous execution, no hidden state
  - **AgentJido native** — First-class integration with Jido agents
  - **Observable** — Structured errors for debugging and agent reasoning
  - **Validated** — Zoi schemas ensure command arguments are well-typed

  ## Quick Start

      # Start a session
      {:ok, session_id} = Jido.Shell.ShellSession.start("my_workspace")

      # Run commands
      Jido.Shell.ShellSessionServer.run_command(session_id, "pwd")
      Jido.Shell.ShellSessionServer.run_command(session_id, "ls")

  """

  @doc """
  Returns the current Jido.Shell version.

  ## Examples

      iex> Jido.Shell.version()
      "3.0.0-dev"

  """
  @spec version() :: String.t()
  def version do
    Application.spec(:jido_shell, :vsn) |> to_string()
  end
end
