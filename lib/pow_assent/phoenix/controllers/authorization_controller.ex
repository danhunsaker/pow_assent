defmodule PowAssent.Phoenix.AuthorizationController do
  @moduledoc false
  use Pow.Extension.Phoenix.Controller.Base

  alias Plug.Conn
  alias PowAssent.Plug
  alias PowAssent.Phoenix.{AuthorizationController, RegistrationController}
  alias PowEmailConfirmation.Phoenix.ControllerCallbacks

  plug :require_authenticated when action in [:delete]
  plug :assign_callback_url when action in [:new, :callback]
  plug :load_user_by_invitation_token when action in [:callback]

  @spec process_new(Conn.t(), map()) :: {:ok, binary(), Conn.t()} | {:error, any(), Conn.t()}
  def process_new(conn, %{"provider" => provider}) do
    Plug.authorize_url(conn, provider, conn.assigns.callback_url)
  end

  @spec respond_new({:ok, binary(), Conn.t()} | {:error, any(), Conn.t()}) :: Conn.t()
  def respond_new({:ok, url, conn}) do
    conn
    |> maybe_store_session_params()
    |> maybe_store_invitation_token()
    |> redirect(external: url)
  end
  def respond_new({:error, error, _conn}), do: handle_strategy_error(error)

  defp maybe_store_session_params(%{private: %{pow_assent_session_params: params}} = conn), do: store_session_params(conn, params)
  defp maybe_store_session_params(conn), do: conn

  defp maybe_store_invitation_token(%{params: %{"invitation_token" => token}} = conn), do: store_invitation_token(conn, token)
  defp maybe_store_invitation_token(conn), do: conn

  @spec process_callback(Conn.t(), map()) :: {:ok, Conn.t()} | {:error, Conn.t()} | {:error, {atom(), map()} | map(), Conn.t()}
  def process_callback(conn, %{"provider" => provider} = params) do
    conn
    |> load_session_params()
    |> maybe_assign_invited_user()
    |> Plug.callback(provider, params, conn.assigns.callback_url)
    |> upsert_identity_or_authenticate_or_create_user()
  end

  defp load_session_params(conn) do
    case fetch_session_params(conn) do
      {params, conn} -> Conn.put_private(conn, :pow_assent_session_params, params)
      conn           -> conn
    end
  end

  defp maybe_assign_invited_user(%{assigns: %{invited_user: invited_user}} = conn) do
    config = Pow.Plug.fetch_config(conn)

    Pow.Plug.assign_current_user(conn, invited_user, config)
  end
  defp maybe_assign_invited_user(conn), do: conn

  defp upsert_identity_or_authenticate_or_create_user({:ok, user_identity_params, user_params, conn}) do
    case Pow.Plug.current_user(conn) do
      nil   -> authenticate_or_create_user(conn, user_identity_params, user_params)
      _user -> upsert_user_identity(conn, user_identity_params)
    end
  end
  defp upsert_identity_or_authenticate_or_create_user({:error, error, _conn}), do: handle_strategy_error(error)

  defp upsert_user_identity(conn, user_identity_params) do
    conn
    |> Plug.upsert_identity(user_identity_params)
    |> case do
      {:ok, _user, conn}    -> {:ok, conn}
      {:error, error, conn} -> {:error, error, conn}
    end
  end

  defp authenticate_or_create_user(conn, user_identity_params, user_params) do
    case Plug.authenticate(conn, user_identity_params) do
      {:ok, conn}    -> upsert_user_identity(conn, user_identity_params)
      {:error, conn} -> create_user(conn, user_identity_params, user_params)
    end
  end

  defp create_user(conn, user_identity_params, user_params) do
    with true <- registration_path?(conn),
         {:ok, _user, conn} <- Plug.create_user(conn, user_identity_params, user_params)
    do
      {:ok, Conn.put_private(conn, :pow_assent_action, :registration)}
    else
      {:error, error, conn} -> {:error, error, Conn.put_private(conn, :pow_assent_params, %{user_identity: user_identity_params, user: user_params})}
      false -> {:error, conn}
    end
  end

  defp registration_path?(conn) do
    [conn.private.phoenix_router, Helpers]
    |> Module.concat()
    |> function_exported?(:pow_assent_registration_path, 3)
  end

  @spec respond_callback({:ok, Conn.t()} | {:error, Conn.t()} | {:error, {atom(), map()} | map(), Conn.t()}) :: Conn.t()
  def respond_callback({:ok, %{private: %{pow_assent_action: :registration}} = conn}) do
    case email_confirmed_controller_callback(:registration, conn) do
      {:halt, conn} ->
        conn
      {:ok, _user, conn} ->
        conn
        |> put_flash(:info, extension_messages(conn).user_has_been_created(conn))
        |> redirect(to: routes(conn).after_registration_path(conn))
    end
  end
  def respond_callback({:ok, conn}) do
    case email_confirmed_controller_callback(:session, conn) do
      {:halt, conn} ->
        conn
      {:ok, conn} ->
        conn
        |> put_flash(:info, extension_messages(conn).signed_in(conn))
        |> redirect(to: routes(conn).after_sign_in_path(conn))
    end
  end
  def respond_callback({:error, {:bound_to_different_user, _changeset}, conn}) do
    conn
    |> put_flash(:error, extension_messages(conn).account_already_bound_to_other_user(conn))
    |> redirect(to: routes(conn).session_path(conn, :new))
  end
  def respond_callback({:error, {:invalid_user_id_field, _changeset}, %{params: %{"provider" => provider}, private: %{pow_assent_params: params}} = conn}) do
    conn
    |> Conn.put_session(:pow_assent_params, %{provider => params})
    |> redirect(to: routes(conn).path_for(conn, RegistrationController, :add_user_id, [conn.params["provider"]]))
  end
  def respond_callback({:error, _changeset, conn}),
    do: respond_callback({:error, conn})
  def respond_callback({:error, conn}) do
    conn
    |> put_flash(:error, extension_messages(conn).could_not_sign_in(conn))
    |> redirect(to: routes(conn).session_path(conn, :new))
  end

  defp email_confirmed_controller_callback(:registration, conn) do
    ControllerCallbacks.before_respond(Pow.Phoenix.RegistrationController, :create, {:ok, Pow.Plug.current_user(conn), conn}, [])
  end
  defp email_confirmed_controller_callback(:session, conn) do
    ControllerCallbacks.before_respond(Pow.Phoenix.SessionController, :create, {:ok, conn}, [])
  end

  @spec process_delete(Conn.t(), map()) :: {:ok, map(), Conn.t()} | {:error, any(), Conn.t()}
  def process_delete(conn, %{"provider" => provider}) do
    Plug.delete_identity(conn, provider)
  end

  @spec respond_delete({:ok, map(), Conn.t()}) :: Conn.t()
  def respond_delete({:ok, _deleted, conn}) do
    conn
    |> put_flash(:info, extension_messages(conn).authentication_has_been_removed(conn))
    |> redirect(to: after_delete_path(conn))
  end
  def respond_delete({:error, {:no_password, _changeset}, conn}) do
    conn
    |> put_flash(:error, extension_messages(conn).identity_cannot_be_removed_missing_user_password(conn))
    |> redirect(to: after_delete_path(conn))
  end

  defp after_delete_path(conn), do: routes(conn).registration_path(conn, :edit)

  defp assign_callback_url(conn, _opts) do
    url = routes(conn).url_for(conn, AuthorizationController, :callback, [conn.params["provider"]])

    assign(conn, :callback_url, url)
  end

  defp store_session_params(conn, params), do: Conn.put_session(conn, :pow_assent_session_params, params)

  defp fetch_session_params(%{private: %{plug_session: %{"pow_assent_session_params" => params}}} = conn) do
    {params, Conn.put_session(conn, :pow_assent_session_params, nil)}
  end
  defp fetch_session_params(conn), do: conn

  defp store_invitation_token(conn, token), do: Conn.put_session(conn, :pow_assent_invitation_token, token)

  defp load_user_by_invitation_token(%{private: %{plug_session: %{"pow_assent_invitation_token" => token}}} = conn, _opts) do
    conn = Conn.delete_session(conn, :pow_assent_invitation_token)

    conn
    |> PowInvitation.Plug.invited_user_from_token(token)
    |> case do
      nil  -> conn
      user -> PowInvitation.Plug.assign_invited_user(conn, user)
    end
  end
  defp load_user_by_invitation_token(conn, _opts), do: conn

  defp handle_strategy_error(error), do: raise error
end
