defmodule Kodo.Session do
  @moduledoc """
  High-level API for managing Kodo sessions.

  Sessions are GenServer processes that maintain shell state including
  current working directory, environment variables, and command history.
  """

  @doc """
  Starts a new session for the given workspace.

  Returns `{:ok, session_id}` on success.

  ## Options

  - `:session_id` - Custom session ID (default: auto-generated)
  - `:cwd` - Initial working directory (default: "/")
  - `:env` - Initial environment variables (default: %{})
  - `:meta` - Additional metadata (default: %{})

  ## Examples

      iex> {:ok, session_id} = Kodo.Session.start(:my_workspace)
      iex> String.starts_with?(session_id, "sess-")
      true
  """
  @spec start(atom(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def start(workspace_id, opts \\ []) when is_atom(workspace_id) do
    session_id = Keyword.get_lazy(opts, :session_id, &generate_id/0)

    child_spec = {
      Kodo.SessionServer,
      Keyword.merge(opts, session_id: session_id, workspace_id: workspace_id)
    }

    case DynamicSupervisor.start_child(Kodo.SessionSupervisor, child_spec) do
      {:ok, _pid} -> {:ok, session_id}
      {:error, _} = error -> error
    end
  end

  @doc """
  Stops a session.
  """
  @spec stop(String.t()) :: :ok | {:error, :not_found}
  def stop(session_id) do
    case lookup(session_id) do
      {:ok, pid} ->
        DynamicSupervisor.terminate_child(Kodo.SessionSupervisor, pid)
        :ok

      {:error, :not_found} = error ->
        error
    end
  end

  @doc """
  Generates a unique session ID.

  ## Examples

      iex> id = Kodo.Session.generate_id()
      iex> String.starts_with?(id, "sess-")
      true
  """
  @spec generate_id() :: String.t()
  def generate_id do
    "sess-" <> Uniq.UUID.uuid4()
  end

  @doc """
  Returns a via tuple for Registry lookup.

  ## Examples

      iex> Kodo.Session.via_registry("sess-123")
      {:via, Registry, {Kodo.SessionRegistry, "sess-123"}}
  """
  @spec via_registry(String.t()) :: {:via, Registry, {atom(), String.t()}}
  def via_registry(session_id) when is_binary(session_id) do
    {:via, Registry, {Kodo.SessionRegistry, session_id}}
  end

  @doc """
  Looks up a session by ID.

  Returns `{:ok, pid}` if found, `{:error, :not_found}` otherwise.

  ## Examples

      iex> Kodo.Session.lookup("nonexistent")
      {:error, :not_found}
  """
  @spec lookup(String.t()) :: {:ok, pid()} | {:error, :not_found}
  def lookup(session_id) when is_binary(session_id) do
    case Registry.lookup(Kodo.SessionRegistry, session_id) do
      [{pid, _}] -> {:ok, pid}
      [] -> {:error, :not_found}
    end
  end

  @doc """
  Starts a new session with an in-memory VFS mounted at root.

  This is a convenience function for common use cases where you want
  a fully functional session without manually mounting a VFS.

  ## Options

  Same as `start/2`.

  ## Examples

      iex> {:ok, session_id} = Kodo.Session.start_with_vfs(:my_workspace)
      iex> String.starts_with?(session_id, "sess-")
      true
  """
  @spec start_with_vfs(atom(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def start_with_vfs(workspace_id, opts \\ []) when is_atom(workspace_id) do
    if Kodo.VFS.list_mounts(workspace_id) == [] do
      fs_name = :"kodo_vfs_#{workspace_id}_#{System.unique_integer([:positive])}"
      :ok = Kodo.VFS.mount(workspace_id, "/", Depot.Adapter.InMemory, name: fs_name)
    end

    start(workspace_id, opts)
  end
end
