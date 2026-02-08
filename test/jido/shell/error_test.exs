defmodule Jido.Shell.ErrorTest do
  use Jido.Shell.Case, async: true

  alias Jido.Shell.Error

  describe "vfs/3" do
    test "creates a VFS error with correct code" do
      error = Error.vfs(:not_found, "/missing/file")
      assert error.code == {:vfs, :not_found}
    end

    test "includes path in message" do
      error = Error.vfs(:not_found, "/missing/file")
      assert error.message == "not_found: /missing/file"
    end

    test "includes path in context" do
      error = Error.vfs(:not_found, "/some/path")
      assert error.context.path == "/some/path"
    end

    test "merges additional context" do
      error = Error.vfs(:permission_denied, "/protected", %{user: "test"})
      assert error.context.path == "/protected"
      assert error.context.user == "test"
    end

    test "works as an exception" do
      error = Error.vfs(:not_found, "/missing")
      assert Exception.message(error) == "not_found: /missing"
    end
  end

  describe "shell/2" do
    test "creates a shell error with correct code" do
      error = Error.shell(:unknown_command)
      assert error.code == {:shell, :unknown_command}
    end

    test "converts code to message" do
      error = Error.shell(:syntax_error)
      assert error.message == "syntax_error"
    end

    test "includes context" do
      error = Error.shell(:unknown_command, %{name: "foo"})
      assert error.context.name == "foo"
    end

    test "works with empty context" do
      error = Error.shell(:busy)
      assert error.context == %{}
    end
  end

  describe "validation/3" do
    test "creates a validation error with correct code" do
      error = Error.validation("cp", [])
      assert error.code == {:validation, :invalid_args}
    end

    test "includes command in message" do
      error = Error.validation("mv", [])
      assert error.message == "invalid arguments for mv"
    end

    test "includes command and zoi_errors in context" do
      zoi_errors = [%{path: [:source], message: "is required"}]
      error = Error.validation("cp", zoi_errors)
      assert error.context.command == "cp"
      assert error.context.zoi_errors == zoi_errors
    end

    test "merges additional context" do
      error = Error.validation("rm", [], %{hint: "use -r for directories"})
      assert error.context.hint == "use -r for directories"
      assert error.context.command == "rm"
    end
  end

  describe "session/2" do
    test "creates a session error with correct code" do
      error = Error.session(:not_found)
      assert error.code == {:session, :not_found}
    end

    test "converts code to message" do
      error = Error.session(:terminated)
      assert error.message == "terminated"
    end

    test "includes context" do
      error = Error.session(:not_found, %{session_id: "abc123"})
      assert error.context.session_id == "abc123"
    end
  end

  describe "command/2" do
    test "creates a command error with correct code" do
      error = Error.command(:timeout)
      assert error.code == {:command, :timeout}
    end

    test "converts code to message" do
      error = Error.command(:crashed)
      assert error.message == "crashed"
    end

    test "includes context" do
      error = Error.command(:llm_failed, %{provider: "openai", status: 500})
      assert error.context.provider == "openai"
      assert error.context.status == 500
    end
  end

  describe "category/1" do
    test "extracts category from tuple code" do
      assert Error.category(Error.vfs(:not_found, "/path")) == :vfs
      assert Error.category(Error.shell(:busy)) == :shell
      assert Error.category(Error.validation("cmd", [])) == :validation
      assert Error.category(Error.session(:not_found)) == :session
      assert Error.category(Error.command(:timeout)) == :command
    end

    test "returns code for atom codes" do
      error = %Error{code: :generic_error, message: "test"}
      assert Error.category(error) == :generic_error
    end
  end

  describe "reason/1" do
    test "extracts reason from tuple code" do
      assert Error.reason(Error.vfs(:not_found, "/path")) == :not_found
      assert Error.reason(Error.vfs(:permission_denied, "/path")) == :permission_denied
      assert Error.reason(Error.shell(:unknown_command)) == :unknown_command
    end

    test "returns code for atom codes" do
      error = %Error{code: :generic_error, message: "test"}
      assert Error.reason(error) == :generic_error
    end
  end

  describe "pattern matching" do
    test "errors can be pattern matched on code" do
      error = Error.vfs(:not_found, "/missing")

      result =
        case error.code do
          {:vfs, :not_found} -> :file_not_found
          {:vfs, _} -> :other_vfs_error
          _ -> :unknown
        end

      assert result == :file_not_found
    end

    test "context is introspectable" do
      error = Error.vfs(:not_found, "/my/path", %{operation: :read})
      assert error.context.path == "/my/path"
      assert error.context.operation == :read
    end
  end
end
