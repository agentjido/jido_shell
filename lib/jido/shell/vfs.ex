defmodule Jido.Shell.VFS do
  @moduledoc """
  Virtual File System for Kodo workspaces.

  Provides a unified filesystem API over multiple Jido.VFS adapters,
  with mount points routing operations to the appropriate backend.

  ## Example

      # Mount an in-memory filesystem at root
      :ok = Jido.Shell.VFS.mount(:my_workspace, "/", Jido.VFS.Adapter.InMemory, [name: :my_fs])

      # Write a file
      :ok = Jido.Shell.VFS.write_file(:my_workspace, "/hello.txt", "Hello!")

      # Read it back
      {:ok, "Hello!"} = Jido.Shell.VFS.read_file(:my_workspace, "/hello.txt")
  """

  alias Jido.Shell.VFS.MountTable

  @type workspace_id :: atom()
  @type path :: String.t()

  @doc """
  Initializes the VFS mount table.
  Called by Application on startup.
  """
  @spec init() :: :ok
  def init do
    MountTable.init()
  end

  @doc """
  Mounts a Jido.VFS adapter at the given path.
  """
  @spec mount(workspace_id(), path(), module(), keyword()) :: :ok | {:error, term()}
  def mount(workspace_id, mount_path, adapter, opts \\ []) do
    MountTable.mount(workspace_id, mount_path, adapter, opts)
  end

  @doc """
  Unmounts a filesystem at the given path.
  """
  @spec unmount(workspace_id(), path()) :: :ok | {:error, :not_found}
  def unmount(workspace_id, mount_path) do
    MountTable.unmount(workspace_id, mount_path)
  end

  @doc """
  Lists all mounts for a workspace.
  """
  @spec list_mounts(workspace_id()) :: [Jido.Shell.VFS.Mount.t()]
  def list_mounts(workspace_id) do
    MountTable.list(workspace_id)
  end

  # === File Operations ===

  @doc """
  Reads a file from the VFS.
  """
  @spec read_file(workspace_id(), path()) :: {:ok, binary()} | {:error, Jido.Shell.Error.t()}
  def read_file(workspace_id, path) do
    with {:ok, mount, relative_path} <- resolve_path(workspace_id, path) do
      case Jido.VFS.read(mount.filesystem, relative_path) do
        {:ok, _} = result -> result
        {:error, reason} -> {:error, Jido.Shell.Error.vfs(error_code(reason), path)}
      end
    end
  end

  @doc """
  Writes content to a file.
  """
  @spec write_file(workspace_id(), path(), binary()) :: :ok | {:error, Jido.Shell.Error.t()}
  def write_file(workspace_id, path, content) do
    with {:ok, mount, relative_path} <- resolve_path(workspace_id, path) do
      case Jido.VFS.write(mount.filesystem, relative_path, content) do
        :ok -> :ok
        {:error, reason} -> {:error, Jido.Shell.Error.vfs(error_code(reason), path)}
      end
    end
  end

  @doc """
  Deletes a file.
  """
  @spec delete(workspace_id(), path()) :: :ok | {:error, Jido.Shell.Error.t()}
  def delete(workspace_id, path) do
    with {:ok, mount, relative_path} <- resolve_path(workspace_id, path) do
      case Jido.VFS.delete(mount.filesystem, relative_path) do
        :ok -> :ok
        {:error, reason} -> {:error, Jido.Shell.Error.vfs(error_code(reason), path)}
      end
    end
  end

  @doc """
  Lists directory contents.
  """
  @spec list_dir(workspace_id(), path()) :: {:ok, [map()]} | {:error, Jido.Shell.Error.t()}
  def list_dir(workspace_id, path) do
    with {:ok, mount, relative_path} <- resolve_path(workspace_id, path) do
      case Jido.VFS.list_contents(mount.filesystem, relative_path) do
        {:ok, _} = result -> result
        {:error, reason} -> {:error, Jido.Shell.Error.vfs(error_code(reason), path)}
      end
    end
  end

  @doc """
  Gets file/directory stats.
  """
  @spec stat(workspace_id(), path()) :: {:ok, map()} | {:error, Jido.Shell.Error.t()}
  def stat(workspace_id, path) do
    with {:ok, mount, relative_path} <- resolve_path(workspace_id, path) do
      if relative_path == "." do
        name =
          case Path.basename(path) do
            "" -> "/"
            n -> n
          end

        {:ok, %Jido.VFS.Stat.Dir{name: name, size: 0}}
      else
        parent = Path.dirname(relative_path)
        parent = if parent == ".", do: ".", else: parent
        name = Path.basename(relative_path)

        case Jido.VFS.list_contents(mount.filesystem, parent) do
          {:ok, entries} ->
            case Enum.find(entries, fn e -> e.name == name end) do
              nil -> {:error, Jido.Shell.Error.vfs(:not_found, path)}
              entry -> {:ok, entry}
            end

          {:error, reason} ->
            {:error, Jido.Shell.Error.vfs(error_code(reason), path)}
        end
      end
    end
  end

  @doc """
  Checks if a path exists.
  """
  @spec exists?(workspace_id(), path()) :: boolean()
  def exists?(workspace_id, path) do
    case stat(workspace_id, path) do
      {:ok, _} -> true
      {:error, _} -> false
    end
  end

  @doc """
  Creates a directory.
  """
  @spec mkdir(workspace_id(), path()) :: :ok | {:error, Jido.Shell.Error.t()}
  def mkdir(workspace_id, path) do
    with {:ok, mount, relative_path} <- resolve_path(workspace_id, path) do
      dir_path =
        if String.ends_with?(relative_path, "/"),
          do: relative_path,
          else: relative_path <> "/"

      case Jido.VFS.create_directory(mount.filesystem, dir_path) do
        :ok -> :ok
        {:error, reason} -> {:error, Jido.Shell.Error.vfs(error_code(reason), path)}
      end
    end
  end

  # === Private ===

  defp resolve_path(workspace_id, path) do
    path = normalize_path(path)

    case MountTable.resolve(workspace_id, path) do
      {:ok, mount, relative} -> {:ok, mount, relative}
      {:error, :no_mount} -> {:error, Jido.Shell.Error.vfs(:no_mount, path)}
    end
  end

  defp normalize_path(path) do
    path
    |> Path.expand("/")
    |> String.replace(~r{/+}, "/")
  end

  defp error_code(%{__struct__: Jido.VFS.Errors.FileNotFound}), do: :not_found
  defp error_code(%{__struct__: Jido.VFS.Errors.DirectoryNotEmpty}), do: :directory_not_empty
  defp error_code(%{__struct__: Jido.VFS.Errors.NotDirectory}), do: :not_directory
  defp error_code(%{__struct__: Jido.VFS.Errors.PathTraversal}), do: :path_traversal
  defp error_code(%{__struct__: Jido.VFS.Errors.AbsolutePath}), do: :absolute_path
  defp error_code(:unsupported), do: :unsupported
  defp error_code(reason) when is_atom(reason), do: reason
  defp error_code(_), do: :unknown
end
