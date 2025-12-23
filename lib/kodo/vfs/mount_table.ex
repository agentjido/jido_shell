defmodule Kodo.VFS.MountTable do
  @moduledoc """
  ETS-backed mount table for VFS.
  """

  alias Kodo.VFS.Mount

  @table :kodo_vfs_mounts

  @doc """
  Initializes the ETS table.
  """
  @spec init() :: :ok
  def init do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:named_table, :public, :bag])
    end

    :ok
  end

  @doc """
  Mounts a filesystem.
  """
  @spec mount(atom(), String.t(), module(), keyword()) :: :ok | {:error, term()}
  def mount(workspace_id, path, adapter, opts) do
    case Mount.new(path, adapter, opts) do
      {:ok, mount} ->
        :ets.insert(@table, {workspace_id, mount})
        :ok

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Unmounts a filesystem.
  """
  @spec unmount(atom(), String.t()) :: :ok | {:error, :not_found}
  def unmount(workspace_id, path) do
    normalized = normalize_path(path)
    mounts = list(workspace_id)

    case Enum.find(mounts, fn m -> m.path == normalized end) do
      nil ->
        {:error, :not_found}

      mount ->
        :ets.delete_object(@table, {workspace_id, mount})
        :ok
    end
  end

  @doc """
  Lists all mounts for a workspace.
  """
  @spec list(atom()) :: [Mount.t()]
  def list(workspace_id) do
    @table
    |> :ets.lookup(workspace_id)
    |> Enum.map(fn {_ws, mount} -> mount end)
    # Longest first for matching
    |> Enum.sort_by(fn m -> -String.length(m.path) end)
  end

  @doc """
  Resolves a path to its mount and relative path.
  """
  @spec resolve(atom(), String.t()) :: {:ok, Mount.t(), String.t()} | {:error, :no_mount}
  def resolve(workspace_id, path) do
    path = normalize_path(path)
    mounts = list(workspace_id)

    case Enum.find(mounts, fn mount -> path_under_mount?(path, mount.path) end) do
      nil ->
        {:error, :no_mount}

      mount ->
        relative = relative_path(path, mount.path)
        {:ok, mount, relative}
    end
  end

  defp path_under_mount?(_path, "/"), do: true

  defp path_under_mount?(path, mount_path) do
    String.starts_with?(path, mount_path <> "/") or path == mount_path
  end

  defp relative_path(path, "/") do
    String.trim_leading(path, "/")
    |> case do
      "" -> "."
      p -> p
    end
  end

  defp relative_path(path, mount_path) when path == mount_path, do: "."

  defp relative_path(path, mount_path) do
    String.trim_leading(path, mount_path <> "/")
  end

  defp normalize_path("/"), do: "/"
  defp normalize_path(path), do: String.trim_trailing(path, "/")
end
