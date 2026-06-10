if Code.ensure_loaded?(Bash.Filesystem) do
  defmodule Jido.Shell.Backend.Bash.VfsAdapter do
    @moduledoc """
    `Bash.Filesystem` implementation that routes calls to `Jido.Shell.VFS`.

    Used exclusively by `Jido.Shell.Backend.Bash` so that scripts executed by the
    `:bash` library see the same virtual filesystem as Jido shell commands. The
    adapter is configured with the workspace id at session init time:

        {Jido.Shell.Backend.Bash.VfsAdapter, %{workspace_id: "ws1"}}

    The adapter is stateless on its own — it looks up mounts from
    `Jido.Shell.VFS.MountTable` for every call — and buffers `open/write/close`
    streams in the calling process dictionary before flushing on close.

    Only simple `*`/`?` globbing is supported; more elaborate patterns emit a
    single warning per pattern and return an empty list.
    """

    @behaviour Bash.Filesystem

    alias Jido.Shell.VFS

    @impl true
    def exists?(config, path), do: VFS.exists?(ws(config), normalize(path))

    @impl true
    def dir?(config, path) do
      case VFS.stat(ws(config), normalize(path)) do
        {:ok, %Jido.VFS.Stat.Dir{}} -> true
        _ -> false
      end
    end

    @impl true
    def regular?(config, path) do
      case VFS.stat(ws(config), normalize(path)) do
        {:ok, %Jido.VFS.Stat.File{}} -> true
        _ -> false
      end
    end

    @impl true
    def stat(config, path) do
      case VFS.stat(ws(config), normalize(path)) do
        {:ok, entry} -> {:ok, to_file_stat(entry)}
        {:error, _} -> {:error, :enoent}
      end
    end

    @impl true
    def lstat(config, path), do: stat(config, path)

    @impl true
    def read(config, path) do
      case VFS.read_file(ws(config), normalize(path)) do
        {:ok, _} = ok -> ok
        {:error, _} -> {:error, :enoent}
      end
    end

    @impl true
    def write(config, path, content, opts) do
      path = normalize(path)
      binary = IO.iodata_to_binary(content)
      workspace_id = ws(config)

      final_content =
        if Keyword.get(opts, :append, false) do
          case VFS.read_file(workspace_id, path) do
            {:ok, existing} -> existing <> binary
            {:error, _} -> binary
          end
        else
          binary
        end

      case VFS.write_file(workspace_id, path, final_content) do
        :ok -> :ok
        {:error, _} -> {:error, :eacces}
      end
    end

    @impl true
    def mkdir_p(config, path) do
      case VFS.mkdir(ws(config), normalize(path)) do
        :ok ->
          :ok

        {:error, %{code: {:vfs, :already_exists}}} ->
          :ok

        {:error, _} ->
          # Collapse any other VFS failure — `mkdir_p` should be idempotent.
          if VFS.exists?(ws(config), normalize(path)), do: :ok, else: {:error, :eacces}
      end
    end

    @impl true
    def rm(config, path) do
      case VFS.delete(ws(config), normalize(path)) do
        :ok -> :ok
        {:error, _} -> {:error, :enoent}
      end
    end

    @impl true
    def ls(config, path) do
      path = normalize(path)

      case VFS.list_dir(ws(config), path) do
        {:ok, entries} -> {:ok, entries |> Enum.map(& &1.name) |> Enum.sort()}
        {:error, _} -> {:error, :enoent}
      end
    end

    @impl true
    def wildcard(config, pattern, _opts) do
      dir = Path.dirname(pattern)
      base = Path.basename(pattern)

      cond do
        # Only handle simple `*`/`?` patterns in the last path segment.
        not simple_pattern?(base) ->
          require Logger
          Logger.warning("Jido.Shell.Backend.Bash.VfsAdapter: unsupported glob #{inspect(pattern)}")
          []

        true ->
          case VFS.list_dir(ws(config), normalize(dir)) do
            {:ok, entries} ->
              regex = compile_glob(base)

              entries
              |> Enum.filter(fn entry -> Regex.match?(regex, entry.name) end)
              |> Enum.map(fn entry -> Path.join(normalize(dir), entry.name) end)
              |> Enum.sort()

            {:error, _} ->
              []
          end
      end
    end

    @impl true
    def open(config, path, modes) when is_list(modes) do
      cond do
        :write in modes or :append in modes ->
          {:ok, make_device(config, path, :append in modes)}

        :read in modes ->
          case VFS.read_file(ws(config), normalize(path)) do
            {:ok, content} ->
              {:ok, device} = StringIO.open(content)
              {:ok, device}

            {:error, _} ->
              {:error, :enoent}
          end

        true ->
          {:error, :einval}
      end
    end

    def open(_config, _path, _modes), do: {:error, :einval}

    @impl true
    def handle_write(_config, device, data) do
      case Process.get({__MODULE__, device}) do
        %{kind: :write, path: _path, buffer: buffer} = state ->
          Process.put({__MODULE__, device}, %{state | buffer: buffer <> IO.iodata_to_binary(data)})
          :ok

        _ ->
          IO.binwrite(device, data)
      end
    end

    @impl true
    def handle_close(config, device) do
      case Process.get({__MODULE__, device}) do
        %{kind: :write, path: path, append?: append?, buffer: buffer} ->
          Process.delete({__MODULE__, device})
          _ = StringIO.close(device)
          workspace_id = ws(config)

          final =
            if append? do
              case VFS.read_file(workspace_id, path) do
                {:ok, existing} -> existing <> buffer
                {:error, _} -> buffer
              end
            else
              buffer
            end

          case VFS.write_file(workspace_id, path, final) do
            :ok -> :ok
            {:error, _} -> {:error, :eacces}
          end

        _ ->
          _ = StringIO.close(device)
          :ok
      end
    end

    @impl true
    def read_link(_config, _path), do: {:error, :enotsup}

    @impl true
    def read_link_all(_config, _path), do: {:error, :enotsup}

    # === helpers ===

    defp make_device(_config, path, append?) do
      {:ok, device} = StringIO.open("")
      Process.put({__MODULE__, device}, %{kind: :write, path: normalize(path), append?: append?, buffer: ""})
      device
    end

    defp ws(%{workspace_id: wid}) when is_binary(wid), do: wid

    defp normalize(path) when is_binary(path) do
      case Path.type(path) do
        :absolute -> Path.expand(path)
        _ -> Path.expand(path, "/")
      end
    end

    defp to_file_stat(%Jido.VFS.Stat.Dir{}) do
      now = :calendar.universal_time()
      %File.Stat{type: :directory, size: 0, access: :read_write, mode: 0o755, mtime: now, atime: now, ctime: now}
    end

    defp to_file_stat(%Jido.VFS.Stat.File{size: size}) do
      now = :calendar.universal_time()

      %File.Stat{
        type: :regular,
        size: size || 0,
        access: :read_write,
        mode: 0o644,
        mtime: now,
        atime: now,
        ctime: now
      }
    end

    defp simple_pattern?(base), do: String.match?(base, ~r/^[A-Za-z0-9_.*?\-]*$/)

    defp compile_glob(base) do
      source =
        base
        |> Regex.escape()
        |> String.replace("\\*", ".*")
        |> String.replace("\\?", ".")

      Regex.compile!("^" <> source <> "$")
    end
  end
else
  defmodule Jido.Shell.Backend.Bash.VfsAdapter do
    @moduledoc false
  end
end
