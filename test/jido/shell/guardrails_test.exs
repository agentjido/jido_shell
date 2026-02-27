defmodule Jido.Shell.GuardrailsTest do
  use ExUnit.Case, async: true

  alias Jido.Shell.Guardrails
  alias Jido.Shell.Guardrails.Rules.ForbiddenPaths
  alias Jido.Shell.Guardrails.Rules.NamespacePrefixes
  alias Jido.Shell.Guardrails.Rules.RequiredFiles
  alias Jido.Shell.Guardrails.Violation

  test "passes for current repository layout" do
    assert :ok = Guardrails.check(root: File.cwd!())
  end

  test "forbidden path rule flags legacy namespace paths" do
    with_tmp_dir(fn root ->
      legacy_file = Path.join(root, "lib/kodo/transport/term_ui.ex")
      File.mkdir_p!(Path.dirname(legacy_file))
      File.write!(legacy_file, "defmodule Kodo.Transport.TermUI do\nend\n")

      assert {:error, violations} = Guardrails.check(root: root, rules: [ForbiddenPaths])

      assert Enum.any?(violations, fn %Violation{file: file, message: message} ->
               file == "lib/kodo" and String.contains?(message, "legacy namespace path exists")
             end)
    end)
  end

  test "required file rule flags missing canonical modules" do
    with_tmp_dir(fn root ->
      assert {:error, violations} = Guardrails.check(root: root, rules: [RequiredFiles])

      assert Enum.any?(violations, fn %Violation{file: file, message: message} ->
               file == "lib/jido/shell/shell_session.ex" and
                 String.contains?(message, "missing required file")
             end)
    end)
  end

  test "namespace prefix rule flags incorrect module prefixes" do
    with_tmp_dir(fn root ->
      path = Path.join(root, "lib/jido/shell/command/bad.ex")
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "defmodule Kodo.Command.Bad do\nend\n")

      assert {:error, violations} = Guardrails.check(root: root, rules: [NamespacePrefixes])

      assert Enum.any?(violations, fn %Violation{file: file, message: message} ->
               file == "lib/jido/shell/command/bad.ex" and
                 String.contains?(message, "expected prefix Jido.Shell")
             end)
    end)
  end

  defp with_tmp_dir(fun) do
    root = Path.join(System.tmp_dir!(), "jido-shell-guardrails-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)

    try do
      fun.(root)
    after
      File.rm_rf!(root)
    end
  end
end
