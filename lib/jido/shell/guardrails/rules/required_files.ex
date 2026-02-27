defmodule Jido.Shell.Guardrails.Rules.RequiredFiles do
  @moduledoc false
  @behaviour Jido.Shell.Guardrails.Rule

  alias Jido.Shell.Guardrails.Violation

  @required_content %{
    "lib/jido/shell/shell_session.ex" => [
      "defmodule Jido.Shell.ShellSession do"
    ],
    "lib/jido/shell/shell_session_server.ex" => [
      "defmodule Jido.Shell.ShellSessionServer do"
    ],
    "lib/jido/shell/shell_session/state.ex" => [
      "defmodule Jido.Shell.ShellSession.State do"
    ],
    "lib/jido/shell/session.ex" => [
      "defmodule Jido.Shell.Session do",
      "@moduledoc deprecated:"
    ],
    "lib/jido/shell/session_server.ex" => [
      "defmodule Jido.Shell.SessionServer do",
      "@moduledoc deprecated:"
    ],
    "lib/jido/shell/session/state.ex" => [
      "defmodule Jido.Shell.Session.State do",
      "@moduledoc deprecated:"
    ]
  }

  @impl true
  def check(%{root: root}) do
    Enum.flat_map(@required_content, fn {relative_path, snippets} ->
      full_path = Path.join(root, relative_path)

      case File.read(full_path) do
        {:ok, contents} ->
          snippets
          |> Enum.reject(&String.contains?(contents, &1))
          |> Enum.map(fn snippet ->
            %Violation{
              rule: __MODULE__,
              file: relative_path,
              message: "missing expected content: #{snippet}"
            }
          end)

        {:error, _reason} ->
          [
            %Violation{
              rule: __MODULE__,
              file: relative_path,
              message: "missing required file"
            }
          ]
      end
    end)
  end
end
