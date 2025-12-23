defmodule Kodo.Agent do
  @moduledoc """
  Agent-friendly API for Kodo sessions.

  This module provides a simple, synchronous API suitable for
  Jido agents and other programmatic access patterns.

  ## Usage

      # Start a session
      {:ok, session} = Kodo.Agent.new(:my_workspace)

      # Run commands synchronously
      {:ok, output} = Kodo.Agent.run(session, "ls")
      {:ok, output} = Kodo.Agent.run(session, "cat file.txt")

      # Direct file operations
      :ok = Kodo.Agent.write_file(session, "/path/to/file.txt", "content")
      {:ok, content} = Kodo.Agent.read_file(session, "/path/to/file.txt")

      # Get session state
      {:ok, state} = Kodo.Agent.state(session)

  """

  alias Kodo.Session
  alias Kodo.SessionServer

  @type session :: String.t()
  @type result :: {:ok, String.t()} | {:error, Kodo.Error.t()}

  @doc """
  Creates a new session with in-memory VFS.

  Returns the session ID which can be used for subsequent operations.
  """
  @spec new(atom(), keyword()) :: {:ok, session()} | {:error, term()}
  def new(workspace_id, opts \\ []) when is_atom(workspace_id) do
    Session.start_with_vfs(workspace_id, opts)
  end

  @doc """
  Runs a command and waits for completion.

  Returns the collected output or error.
  """
  @spec run(session(), String.t(), keyword()) :: result()
  def run(session_id, command, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 30_000)

    :ok = SessionServer.subscribe(session_id, self())
    :ok = SessionServer.run_command(session_id, command)

    result = collect_output(session_id, [], timeout)
    :ok = SessionServer.unsubscribe(session_id, self())

    result
  end

  @doc """
  Runs multiple commands in sequence.
  """
  @spec run_all(session(), [String.t()], keyword()) :: [{String.t(), result()}]
  def run_all(session_id, commands, opts \\ []) do
    Enum.map(commands, fn cmd ->
      {cmd, run(session_id, cmd, opts)}
    end)
  end

  @doc """
  Reads a file from the session's VFS.
  """
  @spec read_file(session(), String.t()) :: {:ok, binary()} | {:error, Kodo.Error.t()}
  def read_file(session_id, path) do
    {:ok, state} = SessionServer.get_state(session_id)
    full_path = resolve_path(state.cwd, path)
    Kodo.VFS.read_file(state.workspace_id, full_path)
  end

  @doc """
  Writes a file to the session's VFS.
  """
  @spec write_file(session(), String.t(), binary()) :: :ok | {:error, Kodo.Error.t()}
  def write_file(session_id, path, content) do
    {:ok, state} = SessionServer.get_state(session_id)
    full_path = resolve_path(state.cwd, path)
    Kodo.VFS.write_file(state.workspace_id, full_path, content)
  end

  @doc """
  Lists directory contents.
  """
  @spec list_dir(session(), String.t()) :: {:ok, [map()]} | {:error, Kodo.Error.t()}
  def list_dir(session_id, path \\ ".") do
    {:ok, state} = SessionServer.get_state(session_id)
    full_path = resolve_path(state.cwd, path)
    Kodo.VFS.list_dir(state.workspace_id, full_path)
  end

  @doc """
  Gets the current session state.
  """
  @spec state(session()) :: {:ok, Kodo.Session.State.t()}
  def state(session_id) do
    SessionServer.get_state(session_id)
  end

  @doc """
  Gets the current working directory.
  """
  @spec cwd(session()) :: String.t()
  def cwd(session_id) do
    {:ok, state} = state(session_id)
    state.cwd
  end

  @doc """
  Stops the session.
  """
  @spec stop(session()) :: :ok | {:error, :not_found}
  def stop(session_id) do
    Session.stop(session_id)
  end

  # === Private ===

  defp collect_output(session_id, acc, timeout) do
    receive do
      {:kodo_session, ^session_id, {:command_started, _}} ->
        collect_output(session_id, acc, timeout)

      {:kodo_session, ^session_id, {:output, chunk}} ->
        collect_output(session_id, [chunk | acc], timeout)

      {:kodo_session, ^session_id, {:cwd_changed, _}} ->
        collect_output(session_id, acc, timeout)

      {:kodo_session, ^session_id, :command_done} ->
        output = acc |> Enum.reverse() |> Enum.join()
        {:ok, output}

      {:kodo_session, ^session_id, {:error, error}} ->
        {:error, error}

      {:kodo_session, ^session_id, :command_cancelled} ->
        {:error, Kodo.Error.command(:cancelled)}

      {:kodo_session, ^session_id, {:command_crashed, reason}} ->
        {:error, Kodo.Error.command(:crashed, %{reason: reason})}
    after
      timeout ->
        {:error, Kodo.Error.command(:timeout)}
    end
  end

  defp resolve_path(_cwd, "/" <> _ = path), do: path
  defp resolve_path(cwd, path), do: Path.join(cwd, path) |> Path.expand()
end
