defmodule Jido.Shell.VFSErrorContractTest do
  use ExUnit.Case, async: true
  alias Jido.Shell.Error
  alias Jido.Shell.VFS
  alias Jido.VFS.Errors

  defmodule FailedStorage do
    def configure(opts), do: {__MODULE__, Keyword.fetch!(opts, :error)}
    def read(error, _), do: {:error, error}
    def write(error, _, _, _), do: {:error, error}
    def delete(error, _), do: {:error, error}
    def list_contents(error, _), do: {:error, error}
    def create_directory(error, _, _), do: {:error, error}
  end

  test "storage errors retain their category and the requested virtual path" do
    cases = [
      {Errors.FileNotFound.exception(file_path: "file"), :not_found},
      {Errors.DirectoryNotEmpty.exception(dir_path: "dir"), :directory_not_empty},
      {Errors.NotDirectory.exception(not_dir_path: "file"), :not_directory},
      {Errors.PathTraversal.exception(attempted_path: "../file"), :path_traversal},
      {Errors.AbsolutePath.exception(absolute_path: "/host/file"), :absolute_path},
      {Errors.AdapterError.exception(adapter: FailedStorage, reason: :offline), :unknown}
    ]

    for {error, code} <- cases do
      workspace = "failed-storage-#{System.unique_integer([:positive])}"
      assert :ok = VFS.mount(workspace, "/", FailedStorage, error: error)

      try do
        for operation <- [
              &VFS.read_file(&1, "/file"),
              &VFS.write_file(&1, "/file", "bytes"),
              &VFS.delete(&1, "/file"),
              &VFS.list_dir(&1, "/file"),
              &VFS.stat(&1, "/file"),
              &VFS.mkdir(&1, "/file")
            ] do
          assert {:error, %Error{code: {:vfs, ^code}, context: context}} = operation.(workspace)
          assert context.path == "/file"
        end

        refute VFS.exists?(workspace, "/file")
      after
        assert :ok = VFS.unmount(workspace, "/")
      end
    end
  end
end
