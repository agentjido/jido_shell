defmodule Kodo.TestShell do
  @moduledoc """
  Test helper for E2E shell testing.

  Provides a synchronous, deterministic interface for testing
  Kodo shell workflows with proper isolation and cleanup.

  ## Usage

      test "basic workflow" do
        shell = TestShell.start!()

        # Run commands synchronously
        assert {:ok, "/"} = TestShell.run(shell, "pwd")
        assert {:ok, ""} = TestShell.run(shell, "mkdir /projects")
        assert {:ok, "/projects"} = TestShell.run(shell, "cd /projects && pwd")

        # File operations
        TestShell.write_file!(shell, "/test.txt", "hello")
        assert TestShell.read_file!(shell, "/test.txt") == "hello"

        # Cleanup happens automatically via on_exit
      end

  ## Multi-process testing

      test "concurrent access" do
        shell = TestShell.start!()

        # Spawn a "user" process
        task = Task.async(fn ->
          TestShell.run(shell, "sleep 0.1")
        end)

        # Main process tries to run while busy
        assert {:error, :busy} = TestShell.run(shell, "echo hi", timeout: 50)

        Task.await(task)
      end
  """

  alias Kodo.Agent
  alias Kodo.Session
  alias Kodo.SessionServer
  alias Kodo.VFS

  defstruct [:session_id, :workspace_id, :owner]

  @type t :: %__MODULE__{
          session_id: String.t(),
          workspace_id: atom(),
          owner: pid()
        }

  @default_timeout 5_000

  @doc """
  Starts a new isolated shell for testing.

  Automatically registers cleanup via ExUnit on_exit.
  """
  @spec start!(keyword()) :: t()
  def start!(opts \\ []) do
    workspace_id =
      Keyword.get_lazy(opts, :workspace_id, fn ->
        :"test_shell_#{System.unique_integer([:positive])}"
      end)

    # Setup VFS
    VFS.init()
    fs_name = :"test_fs_#{System.unique_integer([:positive])}"
    :ok = VFS.mount(workspace_id, "/", Hako.Adapter.InMemory, name: fs_name)

    # Create session
    {:ok, session_id} = Session.start(workspace_id, Keyword.take(opts, [:cwd, :env]))

    shell = %__MODULE__{
      session_id: session_id,
      workspace_id: workspace_id,
      owner: self()
    }

    # Register cleanup
    ExUnit.Callbacks.on_exit(fn ->
      cleanup(shell)
    end)

    shell
  end

  @doc """
  Runs a command and returns the trimmed output.

  Handles chained commands (e.g., "cd /foo && pwd") by running sequentially.
  """
  @spec run(t(), String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def run(%__MODULE__{session_id: session_id}, command, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    case Agent.run(session_id, command, timeout: timeout) do
      {:ok, output} -> {:ok, String.trim(output)}
      {:error, %Kodo.Error{code: {:shell, :busy}}} -> {:error, :busy}
      {:error, %Kodo.Error{code: {:shell, :unknown_command}}} -> {:error, :unknown_command}
      {:error, %Kodo.Error{code: {:shell, :empty_command}}} -> {:error, :empty_command}
      {:error, %Kodo.Error{} = error} -> {:error, error}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Runs a command and asserts success, returning output.
  """
  @spec run!(t(), String.t(), keyword()) :: String.t()
  def run!(shell, command, opts \\ []) do
    case run(shell, command, opts) do
      {:ok, output} -> output
      {:error, reason} -> raise "Command failed: #{command} - #{inspect(reason)}"
    end
  end

  @doc """
  Runs multiple commands in sequence, returning all results.
  """
  @spec run_all(t(), [String.t()], keyword()) :: [{String.t(), {:ok, String.t()} | {:error, term()}}]
  def run_all(%__MODULE__{} = shell, commands, opts \\ []) do
    Enum.map(commands, fn cmd ->
      {cmd, run(shell, cmd, opts)}
    end)
  end

  @doc """
  Gets the current working directory.
  """
  @spec cwd(t()) :: String.t()
  def cwd(%__MODULE__{session_id: session_id}) do
    Agent.cwd(session_id)
  end

  @doc """
  Writes a file to the VFS.
  """
  @spec write_file(t(), String.t(), binary()) :: :ok | {:error, term()}
  def write_file(%__MODULE__{session_id: session_id}, path, content) do
    Agent.write_file(session_id, path, content)
  end

  @spec write_file!(t(), String.t(), binary()) :: :ok
  def write_file!(shell, path, content) do
    :ok = write_file(shell, path, content)
  end

  @doc """
  Reads a file from the VFS.
  """
  @spec read_file(t(), String.t()) :: {:ok, binary()} | {:error, term()}
  def read_file(%__MODULE__{session_id: session_id}, path) do
    Agent.read_file(session_id, path)
  end

  @spec read_file!(t(), String.t()) :: binary()
  def read_file!(shell, path) do
    case read_file(shell, path) do
      {:ok, content} -> content
      {:error, reason} -> raise "Failed to read #{path}: #{inspect(reason)}"
    end
  end

  @doc """
  Lists directory contents.
  """
  @spec ls(t(), String.t()) :: {:ok, [String.t()]} | {:error, term()}
  def ls(%__MODULE__{session_id: session_id}, path \\ ".") do
    case Agent.list_dir(session_id, path) do
      {:ok, entries} -> {:ok, Enum.map(entries, & &1.name)}
      {:error, _} = error -> error
    end
  end

  @spec ls!(t(), String.t()) :: [String.t()]
  def ls!(shell, path \\ ".") do
    case ls(shell, path) do
      {:ok, entries} -> entries
      {:error, reason} -> raise "Failed to list #{path}: #{inspect(reason)}"
    end
  end

  @doc """
  Checks if a path exists.
  """
  @spec exists?(t(), String.t()) :: boolean()
  def exists?(%__MODULE__{workspace_id: workspace_id, session_id: session_id}, path) do
    {:ok, state} = SessionServer.get_state(session_id)
    full_path = resolve_path(state.cwd, path)
    VFS.exists?(workspace_id, full_path)
  end

  @doc """
  Gets the session state.
  """
  @spec state(t()) :: Kodo.Session.State.t()
  def state(%__MODULE__{session_id: session_id}) do
    {:ok, state} = SessionServer.get_state(session_id)
    state
  end

  @doc """
  Gets environment variables.
  """
  @spec env(t()) :: map()
  def env(shell) do
    state(shell).env
  end

  @doc """
  Subscribes the calling process to session events.

  Useful for testing event streaming.
  """
  @spec subscribe(t()) :: :ok
  def subscribe(%__MODULE__{session_id: session_id}) do
    SessionServer.subscribe(session_id, self())
  end

  @doc """
  Unsubscribes from session events.
  """
  @spec unsubscribe(t()) :: :ok
  def unsubscribe(%__MODULE__{session_id: session_id}) do
    SessionServer.unsubscribe(session_id, self())
  end

  @doc """
  Runs a command asynchronously, useful for testing cancellation.
  """
  @spec run_async(t(), String.t()) :: :ok
  def run_async(%__MODULE__{session_id: session_id}, command) do
    SessionServer.run_command(session_id, command)
  end

  @doc """
  Cancels the currently running command.
  """
  @spec cancel(t()) :: :ok
  def cancel(%__MODULE__{session_id: session_id}) do
    SessionServer.cancel(session_id)
  end

  @doc """
  Waits for a specific event from the session.
  """
  @spec await_event(t(), atom() | tuple(), timeout()) :: {:ok, term()} | {:error, :timeout}
  def await_event(%__MODULE__{session_id: session_id}, event_match, timeout \\ @default_timeout) do
    receive do
      {:kodo_session, ^session_id, event} when event == event_match ->
        {:ok, event}

      {:kodo_session, ^session_id, event} ->
        case match_event?(event, event_match) do
          true -> {:ok, event}
          false -> await_event(%__MODULE__{session_id: session_id}, event_match, timeout)
        end
    after
      timeout -> {:error, :timeout}
    end
  end

  @doc """
  Collects all events until :command_done or timeout.
  """
  @spec collect_events(t(), timeout()) :: [term()]
  def collect_events(%__MODULE__{session_id: session_id}, timeout \\ @default_timeout) do
    do_collect_events(session_id, [], timeout)
  end

  # Private helpers

  defp do_collect_events(session_id, acc, timeout) do
    receive do
      {:kodo_session, ^session_id, :command_done} ->
        Enum.reverse([:command_done | acc])

      {:kodo_session, ^session_id, :command_cancelled} ->
        Enum.reverse([:command_cancelled | acc])

      {:kodo_session, ^session_id, {:command_crashed, _} = event} ->
        Enum.reverse([event | acc])

      {:kodo_session, ^session_id, event} ->
        do_collect_events(session_id, [event | acc], timeout)
    after
      timeout -> Enum.reverse(acc)
    end
  end

  defp match_event?({tag, _}, tag) when is_atom(tag), do: true
  defp match_event?(event, event), do: true
  defp match_event?(_, _), do: false

  defp cleanup(%__MODULE__{session_id: session_id, workspace_id: workspace_id}) do
    # Stop session if still running
    case Session.lookup(session_id) do
      {:ok, _} -> Session.stop(session_id)
      {:error, :not_found} -> :ok
    end

    # Cleanup VFS mounts
    VFS.unmount(workspace_id, "/")
  catch
    _, _ -> :ok
  end

  defp resolve_path(_cwd, "/" <> _ = path), do: path
  defp resolve_path(cwd, path), do: Path.join(cwd, path) |> Path.expand()
end
