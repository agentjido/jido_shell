defmodule Jido.Shell.Command.Write do
  @moduledoc """
  Writes content to a file.

  ## Usage

      write <filename> <content>
  """

  @behaviour Jido.Shell.Command

  @impl true
  def name, do: "write"

  @impl true
  def summary, do: "Write content to a file"

  @impl true
  def schema do
    Zoi.map(%{
      args: Zoi.array(Zoi.string()) |> Zoi.default([])
    })
  end

  @impl true
  def run(state, args, emit) do
    case args.args do
      [] ->
        {:error, Jido.Shell.Error.validation("write", [%{message: "usage: write <file> <content>"}])}

      [_file] ->
        {:error, Jido.Shell.Error.validation("write", [%{message: "usage: write <file> <content>"}])}

      [file | content_parts] ->
        path = resolve_path(state.cwd, file)
        content = Enum.join(content_parts, " ")

        case Jido.Shell.VFS.write_file(state.workspace_id, path, content) do
          :ok ->
            emit.({:output, "wrote #{byte_size(content)} bytes to #{path}\n"})
            {:ok, nil}

          {:error, _} = error ->
            error
        end
    end
  end

  defp resolve_path(_cwd, "/" <> _ = path), do: Path.expand(path)
  defp resolve_path(cwd, path), do: Path.join(cwd, path) |> Path.expand()
end
