defmodule Jido.Shell.Backend do
  @moduledoc """
  Behaviour for shell command execution backends.

  Backends encapsulate command execution so `ShellSessionServer` can dispatch to
  local or remote runtimes without changing the public API.
  """

  @typedoc "Backend-specific opaque runtime state."
  @type state :: term()

  @typedoc "Opaque command handle returned by a backend for cancellation."
  @type command_ref :: term()

  @type exec_opts :: [
          dir: String.t(),
          env: %{optional(String.t()) => String.t()},
          timeout: pos_integer(),
          output_limit: pos_integer(),
          execution_context: map(),
          session_state: Jido.Shell.ShellSession.State.t()
        ]

  @doc "Initialize backend state for a session."
  @callback init(config :: map()) :: {:ok, state()} | {:error, term()}

  @doc "Execute a command and return a command reference plus updated backend state."
  @callback execute(state(), command :: String.t(), args :: [String.t()], exec_opts()) ::
              {:ok, command_ref(), state()} | {:error, term()}

  @doc "Cancel a running command."
  @callback cancel(state(), command_ref()) :: :ok | {:error, term()}

  @doc "Clean up backend resources when a session terminates."
  @callback terminate(state()) :: :ok

  @doc "Return the backend current working directory."
  @callback cwd(state()) :: {:ok, String.t(), state()} | {:error, term()}

  @doc "Change the backend current working directory."
  @callback cd(state(), path :: String.t()) :: {:ok, state()} | {:error, term()}

  @doc "Apply backend-specific network policy."
  @callback configure_network(state(), policy :: map()) :: {:ok, state()} | {:error, term()}

  @optional_callbacks configure_network: 2
end
