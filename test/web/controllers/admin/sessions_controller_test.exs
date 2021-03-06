defmodule AlloyCi.Web.SessionControllerTest do
  @moduledoc """
  """
  use AlloyCi.Web.ConnCase

  import AlloyCi.Factory

  alias AlloyCi.{Guardian, User}

  setup do
    auth = insert(:user) |> User.make_admin!() |> with_authentication
    {:ok, %{user: auth.user}}
  end

  describe "GET /login" do
    test "when not logged in as admin", %{conn: conn} do
      conn = get(conn, admin_login_path(conn, :new))
      assert html_response(conn, 200)
    end

    test "when logged in as a normal user", %{user: user} do
      conn = guardian_login(user)
      conn = get(conn, admin_login_path(conn, :new))
      assert html_response(conn, 200)
    end
  end

  test "POST /login when not logged in", %{conn: conn, user: user} do
    conn =
      conn
      |> post(
        admin_session_path(build_conn(), :callback, "identity"),
        email: user.email,
        password: "sekrit"
      )

    assert html_response(conn, 302)
    assert Guardian.Plug.current_resource(conn, key: :admin).id == user.id
    assert Guardian.Plug.current_resource(conn) == nil
  end

  test "DELETE /logout when logged in", %{user: user} do
    conn =
      guardian_login(user, %{typ: "access"}, key: :admin)
      |> bypass_through(AlloyCi.Web.Router, [:browser, :admin_browser_auth])
      |> get("/")

    refute Guardian.Plug.current_resource(conn, key: :admin) == nil
    assert Guardian.Plug.current_resource(conn, key: :admin).id == user.id

    conn = delete(recycle(conn), admin_logout_path(conn, :logout))
    assert Guardian.Plug.current_resource(conn, key: :admin) == nil
  end
end
