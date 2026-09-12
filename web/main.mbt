///|
/// Channel id shared with the pi extension's WebSocket endpoint.
const WS_ID : String = "pi"

///|
enum Msg {
  Recv(String)
  SendState
}

///|
struct Model {
  log : Array[String]
} derive(Eq)

///|
fn initial() -> Model {
  { log: [] }
}

///|
fn update(
  model : Model,
  msg : Msg,
  _emit : @cmd.Emit[Msg],
) -> (Model, @cmd.Cmd) {
  match msg {
    Recv(text) => ({ log: model.log + [text] }, @cmd.none)
    SendState =>
      (
        model,
        @websocket.send(
          WS_ID,
          @websocket.Payload::Text("{\"id\":\"m1\",\"type\":\"get_state\"}"),
        ),
      )
  }
}

///|
fn view(model : Model, emit : @cmd.Emit[Msg]) -> @html.Html {
  @html.div([
    @html.h1("pi-web-shell"),
    @html.button(on_click=emit(SendState), "get_state"),
    @html.ul(model.log.map(fn(s) { @html.li(s) })),
  ])
}

///|
fn subscriptions(_model : Model, emit : @cmd.Emit[Msg]) -> @sub.Sub {
  @websocket.listen(WS_ID, message=emit.map(fn(text) { Recv(text) }))
}

///|
fn main {
  @rabbita
  .elmish(
    model=initial(),
    view=view,
    update=update,
    subscriptions=subscriptions,
  )
  .mount("app")
}
