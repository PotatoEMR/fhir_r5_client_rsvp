////[https://hl7.org/fhir/r5](https://hl7.org/fhir/r5) r5 client using rsvp

import fhir/r5/resources
import fhir/r5/sansio.{type FhirClient}
import fhir/r5/search_params
import gleam/dynamic/decode.{type Decoder}
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/io
import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import lustre/effect.{type Effect}
import rsvp

pub type Err {
  ErrRsvp(err: rsvp.Error(String))
  ErrSansio(err: sansio.ErrResp)
}

/// When using rsvp, if you attempt update or delete a resource with no id,
/// we do not even send the request or give you an effect to use.
/// Instead of an effect you get just Error(ErrNoId)
pub type ErrNoId {
  ErrNoId
}

fn any_create(
  resource: Json,
  res_type: resources.ResourceType,
  resource_dec: Decoder(r),
  client: FhirClient,
  handle_response: fn(Result(r, Err)) -> a,
) -> Effect(a) {
  let req = sansio.any_create_req(resource, res_type, client)
  sendreq_handleresponse(req, resource_dec, res_type, handle_response, client)
}

fn any_read(
  id: String,
  res_type: resources.ResourceType,
  resource_dec: Decoder(r),
  client: FhirClient,
  handle_response: fn(Result(r, Err)) -> a,
) -> Effect(a) {
  let req = sansio.any_read_req(id, res_type, client)
  sendreq_handleresponse(req, resource_dec, res_type, handle_response, client)
}

fn any_update(
  id: Option(String),
  resource: Json,
  res_type: resources.ResourceType,
  resource_dec: Decoder(r),
  client: FhirClient,
  handle_response: fn(Result(r, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  let req = sansio.any_update_req(id, resource, res_type, client)
  case req {
    Ok(req) ->
      Ok(sendreq_handleresponse(
        req,
        resource_dec,
        res_type,
        handle_response,
        client,
      ))
    // from rsvp's point of view it would make more sense to split sansio error into 2 separate errors
    // since user creates request and gets effect or error, then sends and gets response or error
    // ie you know first error must be creating error, and second must be http or parsing error
    // that said, currently you can only get error creating request from calling update/delete on resource with no id
    // so maybe it's easy to ignore all of this
    Error(_) -> Error(ErrNoId)
  }
}

pub fn any_delete(
  id: String,
  res_type: resources.ResourceType,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Effect(a) {
  let req = sansio.any_delete_req(id, res_type, client)
  case client.print_sent_requests {
    sansio.LoggingOn -> req |> sansio.req_to_string |> io.println
    sansio.LoggingOff -> Nil
  }
  let handle_read = fn(resp_res: Result(Response(String), rsvp.Error(String))) {
    case client.print_received_responses {
      sansio.LoggingOn ->
        case resp_res {
          Ok(resp) -> resp |> sansio.resp_to_string
          Error(err) -> err |> rsvp_err_to_string
        }
        |> io.println
      sansio.LoggingOff -> Nil
    }
    handle_response(case resp_res {
      Error(err) -> Error(ErrRsvp(err))
      Ok(resp) ->
        case sansio.http_or_operationoutcome_resp(resp) {
          Ok(oo_or_http) -> Ok(oo_or_http)
          Error(err) -> Error(ErrSansio(err))
        }
    })
  }
  let handler = rsvp.expect_any_response(handle_read)
  req
  |> request.set_body(case req.body {
    None -> ""
    Some(body) -> json.to_string(body)
  })
  |> rsvp.send(handler)
}

/// write out search string manually, in case typed search params don't work
pub fn search_any(
  search_string: String,
  res_type: resources.ResourceType,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  let req = sansio.any_search_req(search_string, res_type, client)
  sendreq_handleresponse(
    req,
    resources.bundle_decoder(),
    resources.RtBundle,
    handle_response,
    client,
  )
}

/// instead of failing whole decoder on bundle entry with invalid resource,
/// return valid resources alongside list of errors
pub fn search_any_forgiving(
  search_string: String,
  res_type: resources.ResourceType,
  client: FhirClient,
  handle_response: fn(Result(resources.BundleForgiving, Err)) -> msg,
) -> Effect(msg) {
  let req = sansio.any_search_req(search_string, res_type, client)
  sendreq_handleresponse(
    req,
    resources.bundle_decoder_forgiving(),
    resources.RtBundle,
    handle_response,
    client,
  )
}

// run any operation string on any resource string, optionally using Parameters
pub fn operation_any(
  params params: Option(resources.Parameters),
  operation_name operation_name: String,
  res_type res_type: resources.ResourceType,
  res_id res_id: Option(String),
  res_decoder res_decoder: Decoder(res),
  return_res_type return_res_type: resources.ResourceType,
  client client: FhirClient,
  handle_response handle_response: fn(Result(res, Err)) -> msg,
) -> Effect(msg) {
  let req =
    sansio.any_operation_req(res_type, res_id, operation_name, params, client)
  sendreq_handleresponse(
    req,
    res_decoder,
    return_res_type,
    handle_response,
    client,
  )
}

pub fn batch(
  reqs: List(Request(Option(Json))),
  bundle_type: sansio.PostBundleType,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  let req = sansio.batch_req(reqs, bundle_type, client)
  sendreq_handleresponse(
    req,
    resources.bundle_decoder(),
    resources.RtBundle,
    handle_response,
    client,
  )
}

fn sendreq_handleresponse(
  req: Request(Option(Json)),
  res_dec: Decoder(r),
  res_type: resources.ResourceType,
  handle_response: fn(Result(r, Err)) -> a,
  client: FhirClient,
) -> Effect(a) {
  sendreq_handleresponse_andprocess(
    req,
    res_dec,
    res_type,
    handle_response,
    fn(a) { a },
    client,
  )
}

fn sendreq_handleresponse_andprocess(
  req: Request(Option(Json)),
  res_dec: Decoder(r),
  res_type: resources.ResourceType,
  handle_response: fn(Result(b, Err)) -> a,
  process_res: fn(r) -> b,
  client: FhirClient,
) -> Effect(a) {
  case client.print_sent_requests {
    sansio.LoggingOn -> req |> sansio.req_to_string |> io.println
    sansio.LoggingOff -> Nil
  }
  let handle_read = fn(resp_res: Result(Response(String), rsvp.Error(String))) {
    case client.print_received_responses {
      sansio.LoggingOn ->
        case resp_res {
          Ok(resp) -> resp |> sansio.resp_to_string
          Error(err) -> err |> rsvp_err_to_string
        }
        |> io.println
      sansio.LoggingOff -> Nil
    }
    handle_response(case resp_res {
      Error(err) -> Error(ErrRsvp(err))
      Ok(resp_res) -> {
        case sansio.any_resp(resp_res, res_dec, res_type) {
          Ok(res) -> Ok(process_res(res))
          Error(err) -> Error(ErrSansio(err))
        }
      }
    })
  }
  let handler = rsvp.expect_any_response(handle_read)
  req
  |> request.set_body(case req.body {
    None -> ""
    Some(body) -> json.to_string(body)
  })
  |> rsvp.send(handler)
}

fn rsvp_err_to_string(err: rsvp.Error(String)) -> String {
  case err {
    rsvp.BadBody -> "invalid http response body"
    rsvp.BadUrl(url) -> "invalid url: " <> url
    rsvp.HttpError(resp) -> "resp not 2xx: " <> sansio.resp_to_string(resp)
    rsvp.JsonError(err) ->
      "err decoding json: "
      <> case err {
        json.UnexpectedEndOfInput -> "unexpected end of input"
        json.UnexpectedByte(err) -> "unexpected byte: " <> err
        json.UnexpectedSequence(err) -> "unexpected sequence " <> err
        json.UnableToDecode(errors) ->
          "unable to decode: "
          <> list.map(errors, fn(error) {
            "expected "
            <> error.expected
            <> " but found "
            <> error.found
            <> " at "
            <> string.join(error.path, "/")
          })
          |> string.join("\n")
      }
    rsvp.NetworkError ->
      "network error, http request could not connect to server"
    rsvp.UnhandledResponse(resp) ->
      "rsvp handler does not know how to handle response: "
      <> sansio.resp_to_string(resp)
  }
}

pub fn account_create(
  resource: resources.Account,
  client: FhirClient,
  handle_response: fn(Result(resources.Account, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.account_to_json(resource),
    resources.RtAccount,
    resources.account_decoder(),
    client,
    handle_response,
  )
}

pub fn account_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.Account, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtAccount,
    resources.account_decoder(),
    client,
    handle_response,
  )
}

pub fn account_update(
  resource: resources.Account,
  client: FhirClient,
  handle_response: fn(Result(resources.Account, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.account_to_json(resource),
    resources.RtAccount,
    resources.account_decoder(),
    client,
    handle_response,
  )
}

pub fn account_delete(
  resource: resources.Account,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) -> Ok(any_delete(id, resources.RtAccount, client, handle_response))
    None -> Error(ErrNoId)
  }
}

pub fn activitydefinition_create(
  resource: resources.Activitydefinition,
  client: FhirClient,
  handle_response: fn(Result(resources.Activitydefinition, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.activitydefinition_to_json(resource),
    resources.RtActivitydefinition,
    resources.activitydefinition_decoder(),
    client,
    handle_response,
  )
}

pub fn activitydefinition_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.Activitydefinition, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtActivitydefinition,
    resources.activitydefinition_decoder(),
    client,
    handle_response,
  )
}

pub fn activitydefinition_update(
  resource: resources.Activitydefinition,
  client: FhirClient,
  handle_response: fn(Result(resources.Activitydefinition, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.activitydefinition_to_json(resource),
    resources.RtActivitydefinition,
    resources.activitydefinition_decoder(),
    client,
    handle_response,
  )
}

pub fn activitydefinition_delete(
  resource: resources.Activitydefinition,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) ->
      Ok(any_delete(id, resources.RtActivitydefinition, client, handle_response))
    None -> Error(ErrNoId)
  }
}

pub fn actordefinition_create(
  resource: resources.Actordefinition,
  client: FhirClient,
  handle_response: fn(Result(resources.Actordefinition, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.actordefinition_to_json(resource),
    resources.RtActordefinition,
    resources.actordefinition_decoder(),
    client,
    handle_response,
  )
}

pub fn actordefinition_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.Actordefinition, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtActordefinition,
    resources.actordefinition_decoder(),
    client,
    handle_response,
  )
}

pub fn actordefinition_update(
  resource: resources.Actordefinition,
  client: FhirClient,
  handle_response: fn(Result(resources.Actordefinition, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.actordefinition_to_json(resource),
    resources.RtActordefinition,
    resources.actordefinition_decoder(),
    client,
    handle_response,
  )
}

pub fn actordefinition_delete(
  resource: resources.Actordefinition,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) ->
      Ok(any_delete(id, resources.RtActordefinition, client, handle_response))
    None -> Error(ErrNoId)
  }
}

pub fn administrableproductdefinition_create(
  resource: resources.Administrableproductdefinition,
  client: FhirClient,
  handle_response: fn(Result(resources.Administrableproductdefinition, Err)) ->
    a,
) -> Effect(a) {
  any_create(
    resources.administrableproductdefinition_to_json(resource),
    resources.RtAdministrableproductdefinition,
    resources.administrableproductdefinition_decoder(),
    client,
    handle_response,
  )
}

pub fn administrableproductdefinition_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.Administrableproductdefinition, Err)) ->
    a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtAdministrableproductdefinition,
    resources.administrableproductdefinition_decoder(),
    client,
    handle_response,
  )
}

pub fn administrableproductdefinition_update(
  resource: resources.Administrableproductdefinition,
  client: FhirClient,
  handle_response: fn(Result(resources.Administrableproductdefinition, Err)) ->
    a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.administrableproductdefinition_to_json(resource),
    resources.RtAdministrableproductdefinition,
    resources.administrableproductdefinition_decoder(),
    client,
    handle_response,
  )
}

pub fn administrableproductdefinition_delete(
  resource: resources.Administrableproductdefinition,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) ->
      Ok(any_delete(
        id,
        resources.RtAdministrableproductdefinition,
        client,
        handle_response,
      ))
    None -> Error(ErrNoId)
  }
}

pub fn adverseevent_create(
  resource: resources.Adverseevent,
  client: FhirClient,
  handle_response: fn(Result(resources.Adverseevent, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.adverseevent_to_json(resource),
    resources.RtAdverseevent,
    resources.adverseevent_decoder(),
    client,
    handle_response,
  )
}

pub fn adverseevent_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.Adverseevent, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtAdverseevent,
    resources.adverseevent_decoder(),
    client,
    handle_response,
  )
}

pub fn adverseevent_update(
  resource: resources.Adverseevent,
  client: FhirClient,
  handle_response: fn(Result(resources.Adverseevent, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.adverseevent_to_json(resource),
    resources.RtAdverseevent,
    resources.adverseevent_decoder(),
    client,
    handle_response,
  )
}

pub fn adverseevent_delete(
  resource: resources.Adverseevent,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) ->
      Ok(any_delete(id, resources.RtAdverseevent, client, handle_response))
    None -> Error(ErrNoId)
  }
}

pub fn allergyintolerance_create(
  resource: resources.Allergyintolerance,
  client: FhirClient,
  handle_response: fn(Result(resources.Allergyintolerance, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.allergyintolerance_to_json(resource),
    resources.RtAllergyintolerance,
    resources.allergyintolerance_decoder(),
    client,
    handle_response,
  )
}

pub fn allergyintolerance_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.Allergyintolerance, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtAllergyintolerance,
    resources.allergyintolerance_decoder(),
    client,
    handle_response,
  )
}

pub fn allergyintolerance_update(
  resource: resources.Allergyintolerance,
  client: FhirClient,
  handle_response: fn(Result(resources.Allergyintolerance, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.allergyintolerance_to_json(resource),
    resources.RtAllergyintolerance,
    resources.allergyintolerance_decoder(),
    client,
    handle_response,
  )
}

pub fn allergyintolerance_delete(
  resource: resources.Allergyintolerance,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) ->
      Ok(any_delete(id, resources.RtAllergyintolerance, client, handle_response))
    None -> Error(ErrNoId)
  }
}

pub fn appointment_create(
  resource: resources.Appointment,
  client: FhirClient,
  handle_response: fn(Result(resources.Appointment, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.appointment_to_json(resource),
    resources.RtAppointment,
    resources.appointment_decoder(),
    client,
    handle_response,
  )
}

pub fn appointment_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.Appointment, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtAppointment,
    resources.appointment_decoder(),
    client,
    handle_response,
  )
}

pub fn appointment_update(
  resource: resources.Appointment,
  client: FhirClient,
  handle_response: fn(Result(resources.Appointment, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.appointment_to_json(resource),
    resources.RtAppointment,
    resources.appointment_decoder(),
    client,
    handle_response,
  )
}

pub fn appointment_delete(
  resource: resources.Appointment,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) ->
      Ok(any_delete(id, resources.RtAppointment, client, handle_response))
    None -> Error(ErrNoId)
  }
}

pub fn appointmentresponse_create(
  resource: resources.Appointmentresponse,
  client: FhirClient,
  handle_response: fn(Result(resources.Appointmentresponse, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.appointmentresponse_to_json(resource),
    resources.RtAppointmentresponse,
    resources.appointmentresponse_decoder(),
    client,
    handle_response,
  )
}

pub fn appointmentresponse_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.Appointmentresponse, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtAppointmentresponse,
    resources.appointmentresponse_decoder(),
    client,
    handle_response,
  )
}

pub fn appointmentresponse_update(
  resource: resources.Appointmentresponse,
  client: FhirClient,
  handle_response: fn(Result(resources.Appointmentresponse, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.appointmentresponse_to_json(resource),
    resources.RtAppointmentresponse,
    resources.appointmentresponse_decoder(),
    client,
    handle_response,
  )
}

pub fn appointmentresponse_delete(
  resource: resources.Appointmentresponse,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) ->
      Ok(any_delete(
        id,
        resources.RtAppointmentresponse,
        client,
        handle_response,
      ))
    None -> Error(ErrNoId)
  }
}

pub fn artifactassessment_create(
  resource: resources.Artifactassessment,
  client: FhirClient,
  handle_response: fn(Result(resources.Artifactassessment, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.artifactassessment_to_json(resource),
    resources.RtArtifactassessment,
    resources.artifactassessment_decoder(),
    client,
    handle_response,
  )
}

pub fn artifactassessment_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.Artifactassessment, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtArtifactassessment,
    resources.artifactassessment_decoder(),
    client,
    handle_response,
  )
}

pub fn artifactassessment_update(
  resource: resources.Artifactassessment,
  client: FhirClient,
  handle_response: fn(Result(resources.Artifactassessment, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.artifactassessment_to_json(resource),
    resources.RtArtifactassessment,
    resources.artifactassessment_decoder(),
    client,
    handle_response,
  )
}

pub fn artifactassessment_delete(
  resource: resources.Artifactassessment,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) ->
      Ok(any_delete(id, resources.RtArtifactassessment, client, handle_response))
    None -> Error(ErrNoId)
  }
}

pub fn auditevent_create(
  resource: resources.Auditevent,
  client: FhirClient,
  handle_response: fn(Result(resources.Auditevent, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.auditevent_to_json(resource),
    resources.RtAuditevent,
    resources.auditevent_decoder(),
    client,
    handle_response,
  )
}

pub fn auditevent_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.Auditevent, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtAuditevent,
    resources.auditevent_decoder(),
    client,
    handle_response,
  )
}

pub fn auditevent_update(
  resource: resources.Auditevent,
  client: FhirClient,
  handle_response: fn(Result(resources.Auditevent, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.auditevent_to_json(resource),
    resources.RtAuditevent,
    resources.auditevent_decoder(),
    client,
    handle_response,
  )
}

pub fn auditevent_delete(
  resource: resources.Auditevent,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) ->
      Ok(any_delete(id, resources.RtAuditevent, client, handle_response))
    None -> Error(ErrNoId)
  }
}

pub fn basic_create(
  resource: resources.Basic,
  client: FhirClient,
  handle_response: fn(Result(resources.Basic, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.basic_to_json(resource),
    resources.RtBasic,
    resources.basic_decoder(),
    client,
    handle_response,
  )
}

pub fn basic_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.Basic, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtBasic,
    resources.basic_decoder(),
    client,
    handle_response,
  )
}

pub fn basic_update(
  resource: resources.Basic,
  client: FhirClient,
  handle_response: fn(Result(resources.Basic, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.basic_to_json(resource),
    resources.RtBasic,
    resources.basic_decoder(),
    client,
    handle_response,
  )
}

pub fn basic_delete(
  resource: resources.Basic,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) -> Ok(any_delete(id, resources.RtBasic, client, handle_response))
    None -> Error(ErrNoId)
  }
}

pub fn binary_create(
  resource: resources.Binary,
  client: FhirClient,
  handle_response: fn(Result(resources.Binary, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.binary_to_json(resource),
    resources.RtBinary,
    resources.binary_decoder(),
    client,
    handle_response,
  )
}

pub fn binary_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.Binary, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtBinary,
    resources.binary_decoder(),
    client,
    handle_response,
  )
}

pub fn binary_update(
  resource: resources.Binary,
  client: FhirClient,
  handle_response: fn(Result(resources.Binary, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.binary_to_json(resource),
    resources.RtBinary,
    resources.binary_decoder(),
    client,
    handle_response,
  )
}

pub fn binary_delete(
  resource: resources.Binary,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) -> Ok(any_delete(id, resources.RtBinary, client, handle_response))
    None -> Error(ErrNoId)
  }
}

pub fn biologicallyderivedproduct_create(
  resource: resources.Biologicallyderivedproduct,
  client: FhirClient,
  handle_response: fn(Result(resources.Biologicallyderivedproduct, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.biologicallyderivedproduct_to_json(resource),
    resources.RtBiologicallyderivedproduct,
    resources.biologicallyderivedproduct_decoder(),
    client,
    handle_response,
  )
}

pub fn biologicallyderivedproduct_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.Biologicallyderivedproduct, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtBiologicallyderivedproduct,
    resources.biologicallyderivedproduct_decoder(),
    client,
    handle_response,
  )
}

pub fn biologicallyderivedproduct_update(
  resource: resources.Biologicallyderivedproduct,
  client: FhirClient,
  handle_response: fn(Result(resources.Biologicallyderivedproduct, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.biologicallyderivedproduct_to_json(resource),
    resources.RtBiologicallyderivedproduct,
    resources.biologicallyderivedproduct_decoder(),
    client,
    handle_response,
  )
}

pub fn biologicallyderivedproduct_delete(
  resource: resources.Biologicallyderivedproduct,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) ->
      Ok(any_delete(
        id,
        resources.RtBiologicallyderivedproduct,
        client,
        handle_response,
      ))
    None -> Error(ErrNoId)
  }
}

pub fn biologicallyderivedproductdispense_create(
  resource: resources.Biologicallyderivedproductdispense,
  client: FhirClient,
  handle_response: fn(Result(resources.Biologicallyderivedproductdispense, Err)) ->
    a,
) -> Effect(a) {
  any_create(
    resources.biologicallyderivedproductdispense_to_json(resource),
    resources.RtBiologicallyderivedproductdispense,
    resources.biologicallyderivedproductdispense_decoder(),
    client,
    handle_response,
  )
}

pub fn biologicallyderivedproductdispense_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.Biologicallyderivedproductdispense, Err)) ->
    a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtBiologicallyderivedproductdispense,
    resources.biologicallyderivedproductdispense_decoder(),
    client,
    handle_response,
  )
}

pub fn biologicallyderivedproductdispense_update(
  resource: resources.Biologicallyderivedproductdispense,
  client: FhirClient,
  handle_response: fn(Result(resources.Biologicallyderivedproductdispense, Err)) ->
    a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.biologicallyderivedproductdispense_to_json(resource),
    resources.RtBiologicallyderivedproductdispense,
    resources.biologicallyderivedproductdispense_decoder(),
    client,
    handle_response,
  )
}

pub fn biologicallyderivedproductdispense_delete(
  resource: resources.Biologicallyderivedproductdispense,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) ->
      Ok(any_delete(
        id,
        resources.RtBiologicallyderivedproductdispense,
        client,
        handle_response,
      ))
    None -> Error(ErrNoId)
  }
}

pub fn bodystructure_create(
  resource: resources.Bodystructure,
  client: FhirClient,
  handle_response: fn(Result(resources.Bodystructure, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.bodystructure_to_json(resource),
    resources.RtBodystructure,
    resources.bodystructure_decoder(),
    client,
    handle_response,
  )
}

pub fn bodystructure_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.Bodystructure, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtBodystructure,
    resources.bodystructure_decoder(),
    client,
    handle_response,
  )
}

pub fn bodystructure_update(
  resource: resources.Bodystructure,
  client: FhirClient,
  handle_response: fn(Result(resources.Bodystructure, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.bodystructure_to_json(resource),
    resources.RtBodystructure,
    resources.bodystructure_decoder(),
    client,
    handle_response,
  )
}

pub fn bodystructure_delete(
  resource: resources.Bodystructure,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) ->
      Ok(any_delete(id, resources.RtBodystructure, client, handle_response))
    None -> Error(ErrNoId)
  }
}

pub fn bundle_create(
  resource: resources.Bundle,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.bundle_to_json(resource),
    resources.RtBundle,
    resources.bundle_decoder(),
    client,
    handle_response,
  )
}

pub fn bundle_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtBundle,
    resources.bundle_decoder(),
    client,
    handle_response,
  )
}

pub fn bundle_update(
  resource: resources.Bundle,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.bundle_to_json(resource),
    resources.RtBundle,
    resources.bundle_decoder(),
    client,
    handle_response,
  )
}

pub fn bundle_delete(
  resource: resources.Bundle,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) -> Ok(any_delete(id, resources.RtBundle, client, handle_response))
    None -> Error(ErrNoId)
  }
}

pub fn capabilitystatement_create(
  resource: resources.Capabilitystatement,
  client: FhirClient,
  handle_response: fn(Result(resources.Capabilitystatement, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.capabilitystatement_to_json(resource),
    resources.RtCapabilitystatement,
    resources.capabilitystatement_decoder(),
    client,
    handle_response,
  )
}

pub fn capabilitystatement_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.Capabilitystatement, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtCapabilitystatement,
    resources.capabilitystatement_decoder(),
    client,
    handle_response,
  )
}

pub fn capabilitystatement_update(
  resource: resources.Capabilitystatement,
  client: FhirClient,
  handle_response: fn(Result(resources.Capabilitystatement, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.capabilitystatement_to_json(resource),
    resources.RtCapabilitystatement,
    resources.capabilitystatement_decoder(),
    client,
    handle_response,
  )
}

pub fn capabilitystatement_delete(
  resource: resources.Capabilitystatement,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) ->
      Ok(any_delete(
        id,
        resources.RtCapabilitystatement,
        client,
        handle_response,
      ))
    None -> Error(ErrNoId)
  }
}

pub fn careplan_create(
  resource: resources.Careplan,
  client: FhirClient,
  handle_response: fn(Result(resources.Careplan, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.careplan_to_json(resource),
    resources.RtCareplan,
    resources.careplan_decoder(),
    client,
    handle_response,
  )
}

pub fn careplan_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.Careplan, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtCareplan,
    resources.careplan_decoder(),
    client,
    handle_response,
  )
}

pub fn careplan_update(
  resource: resources.Careplan,
  client: FhirClient,
  handle_response: fn(Result(resources.Careplan, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.careplan_to_json(resource),
    resources.RtCareplan,
    resources.careplan_decoder(),
    client,
    handle_response,
  )
}

pub fn careplan_delete(
  resource: resources.Careplan,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) ->
      Ok(any_delete(id, resources.RtCareplan, client, handle_response))
    None -> Error(ErrNoId)
  }
}

pub fn careteam_create(
  resource: resources.Careteam,
  client: FhirClient,
  handle_response: fn(Result(resources.Careteam, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.careteam_to_json(resource),
    resources.RtCareteam,
    resources.careteam_decoder(),
    client,
    handle_response,
  )
}

pub fn careteam_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.Careteam, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtCareteam,
    resources.careteam_decoder(),
    client,
    handle_response,
  )
}

pub fn careteam_update(
  resource: resources.Careteam,
  client: FhirClient,
  handle_response: fn(Result(resources.Careteam, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.careteam_to_json(resource),
    resources.RtCareteam,
    resources.careteam_decoder(),
    client,
    handle_response,
  )
}

pub fn careteam_delete(
  resource: resources.Careteam,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) ->
      Ok(any_delete(id, resources.RtCareteam, client, handle_response))
    None -> Error(ErrNoId)
  }
}

pub fn chargeitem_create(
  resource: resources.Chargeitem,
  client: FhirClient,
  handle_response: fn(Result(resources.Chargeitem, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.chargeitem_to_json(resource),
    resources.RtChargeitem,
    resources.chargeitem_decoder(),
    client,
    handle_response,
  )
}

pub fn chargeitem_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.Chargeitem, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtChargeitem,
    resources.chargeitem_decoder(),
    client,
    handle_response,
  )
}

pub fn chargeitem_update(
  resource: resources.Chargeitem,
  client: FhirClient,
  handle_response: fn(Result(resources.Chargeitem, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.chargeitem_to_json(resource),
    resources.RtChargeitem,
    resources.chargeitem_decoder(),
    client,
    handle_response,
  )
}

pub fn chargeitem_delete(
  resource: resources.Chargeitem,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) ->
      Ok(any_delete(id, resources.RtChargeitem, client, handle_response))
    None -> Error(ErrNoId)
  }
}

pub fn chargeitemdefinition_create(
  resource: resources.Chargeitemdefinition,
  client: FhirClient,
  handle_response: fn(Result(resources.Chargeitemdefinition, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.chargeitemdefinition_to_json(resource),
    resources.RtChargeitemdefinition,
    resources.chargeitemdefinition_decoder(),
    client,
    handle_response,
  )
}

pub fn chargeitemdefinition_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.Chargeitemdefinition, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtChargeitemdefinition,
    resources.chargeitemdefinition_decoder(),
    client,
    handle_response,
  )
}

pub fn chargeitemdefinition_update(
  resource: resources.Chargeitemdefinition,
  client: FhirClient,
  handle_response: fn(Result(resources.Chargeitemdefinition, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.chargeitemdefinition_to_json(resource),
    resources.RtChargeitemdefinition,
    resources.chargeitemdefinition_decoder(),
    client,
    handle_response,
  )
}

pub fn chargeitemdefinition_delete(
  resource: resources.Chargeitemdefinition,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) ->
      Ok(any_delete(
        id,
        resources.RtChargeitemdefinition,
        client,
        handle_response,
      ))
    None -> Error(ErrNoId)
  }
}

pub fn citation_create(
  resource: resources.Citation,
  client: FhirClient,
  handle_response: fn(Result(resources.Citation, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.citation_to_json(resource),
    resources.RtCitation,
    resources.citation_decoder(),
    client,
    handle_response,
  )
}

pub fn citation_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.Citation, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtCitation,
    resources.citation_decoder(),
    client,
    handle_response,
  )
}

pub fn citation_update(
  resource: resources.Citation,
  client: FhirClient,
  handle_response: fn(Result(resources.Citation, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.citation_to_json(resource),
    resources.RtCitation,
    resources.citation_decoder(),
    client,
    handle_response,
  )
}

pub fn citation_delete(
  resource: resources.Citation,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) ->
      Ok(any_delete(id, resources.RtCitation, client, handle_response))
    None -> Error(ErrNoId)
  }
}

pub fn claim_create(
  resource: resources.Claim,
  client: FhirClient,
  handle_response: fn(Result(resources.Claim, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.claim_to_json(resource),
    resources.RtClaim,
    resources.claim_decoder(),
    client,
    handle_response,
  )
}

pub fn claim_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.Claim, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtClaim,
    resources.claim_decoder(),
    client,
    handle_response,
  )
}

pub fn claim_update(
  resource: resources.Claim,
  client: FhirClient,
  handle_response: fn(Result(resources.Claim, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.claim_to_json(resource),
    resources.RtClaim,
    resources.claim_decoder(),
    client,
    handle_response,
  )
}

pub fn claim_delete(
  resource: resources.Claim,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) -> Ok(any_delete(id, resources.RtClaim, client, handle_response))
    None -> Error(ErrNoId)
  }
}

pub fn claimresponse_create(
  resource: resources.Claimresponse,
  client: FhirClient,
  handle_response: fn(Result(resources.Claimresponse, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.claimresponse_to_json(resource),
    resources.RtClaimresponse,
    resources.claimresponse_decoder(),
    client,
    handle_response,
  )
}

pub fn claimresponse_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.Claimresponse, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtClaimresponse,
    resources.claimresponse_decoder(),
    client,
    handle_response,
  )
}

pub fn claimresponse_update(
  resource: resources.Claimresponse,
  client: FhirClient,
  handle_response: fn(Result(resources.Claimresponse, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.claimresponse_to_json(resource),
    resources.RtClaimresponse,
    resources.claimresponse_decoder(),
    client,
    handle_response,
  )
}

pub fn claimresponse_delete(
  resource: resources.Claimresponse,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) ->
      Ok(any_delete(id, resources.RtClaimresponse, client, handle_response))
    None -> Error(ErrNoId)
  }
}

pub fn clinicalimpression_create(
  resource: resources.Clinicalimpression,
  client: FhirClient,
  handle_response: fn(Result(resources.Clinicalimpression, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.clinicalimpression_to_json(resource),
    resources.RtClinicalimpression,
    resources.clinicalimpression_decoder(),
    client,
    handle_response,
  )
}

pub fn clinicalimpression_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.Clinicalimpression, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtClinicalimpression,
    resources.clinicalimpression_decoder(),
    client,
    handle_response,
  )
}

pub fn clinicalimpression_update(
  resource: resources.Clinicalimpression,
  client: FhirClient,
  handle_response: fn(Result(resources.Clinicalimpression, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.clinicalimpression_to_json(resource),
    resources.RtClinicalimpression,
    resources.clinicalimpression_decoder(),
    client,
    handle_response,
  )
}

pub fn clinicalimpression_delete(
  resource: resources.Clinicalimpression,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) ->
      Ok(any_delete(id, resources.RtClinicalimpression, client, handle_response))
    None -> Error(ErrNoId)
  }
}

pub fn clinicalusedefinition_create(
  resource: resources.Clinicalusedefinition,
  client: FhirClient,
  handle_response: fn(Result(resources.Clinicalusedefinition, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.clinicalusedefinition_to_json(resource),
    resources.RtClinicalusedefinition,
    resources.clinicalusedefinition_decoder(),
    client,
    handle_response,
  )
}

pub fn clinicalusedefinition_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.Clinicalusedefinition, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtClinicalusedefinition,
    resources.clinicalusedefinition_decoder(),
    client,
    handle_response,
  )
}

pub fn clinicalusedefinition_update(
  resource: resources.Clinicalusedefinition,
  client: FhirClient,
  handle_response: fn(Result(resources.Clinicalusedefinition, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.clinicalusedefinition_to_json(resource),
    resources.RtClinicalusedefinition,
    resources.clinicalusedefinition_decoder(),
    client,
    handle_response,
  )
}

pub fn clinicalusedefinition_delete(
  resource: resources.Clinicalusedefinition,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) ->
      Ok(any_delete(
        id,
        resources.RtClinicalusedefinition,
        client,
        handle_response,
      ))
    None -> Error(ErrNoId)
  }
}

pub fn codesystem_create(
  resource: resources.Codesystem,
  client: FhirClient,
  handle_response: fn(Result(resources.Codesystem, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.codesystem_to_json(resource),
    resources.RtCodesystem,
    resources.codesystem_decoder(),
    client,
    handle_response,
  )
}

pub fn codesystem_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.Codesystem, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtCodesystem,
    resources.codesystem_decoder(),
    client,
    handle_response,
  )
}

pub fn codesystem_update(
  resource: resources.Codesystem,
  client: FhirClient,
  handle_response: fn(Result(resources.Codesystem, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.codesystem_to_json(resource),
    resources.RtCodesystem,
    resources.codesystem_decoder(),
    client,
    handle_response,
  )
}

pub fn codesystem_delete(
  resource: resources.Codesystem,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) ->
      Ok(any_delete(id, resources.RtCodesystem, client, handle_response))
    None -> Error(ErrNoId)
  }
}

pub fn communication_create(
  resource: resources.Communication,
  client: FhirClient,
  handle_response: fn(Result(resources.Communication, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.communication_to_json(resource),
    resources.RtCommunication,
    resources.communication_decoder(),
    client,
    handle_response,
  )
}

pub fn communication_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.Communication, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtCommunication,
    resources.communication_decoder(),
    client,
    handle_response,
  )
}

pub fn communication_update(
  resource: resources.Communication,
  client: FhirClient,
  handle_response: fn(Result(resources.Communication, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.communication_to_json(resource),
    resources.RtCommunication,
    resources.communication_decoder(),
    client,
    handle_response,
  )
}

pub fn communication_delete(
  resource: resources.Communication,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) ->
      Ok(any_delete(id, resources.RtCommunication, client, handle_response))
    None -> Error(ErrNoId)
  }
}

pub fn communicationrequest_create(
  resource: resources.Communicationrequest,
  client: FhirClient,
  handle_response: fn(Result(resources.Communicationrequest, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.communicationrequest_to_json(resource),
    resources.RtCommunicationrequest,
    resources.communicationrequest_decoder(),
    client,
    handle_response,
  )
}

pub fn communicationrequest_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.Communicationrequest, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtCommunicationrequest,
    resources.communicationrequest_decoder(),
    client,
    handle_response,
  )
}

pub fn communicationrequest_update(
  resource: resources.Communicationrequest,
  client: FhirClient,
  handle_response: fn(Result(resources.Communicationrequest, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.communicationrequest_to_json(resource),
    resources.RtCommunicationrequest,
    resources.communicationrequest_decoder(),
    client,
    handle_response,
  )
}

pub fn communicationrequest_delete(
  resource: resources.Communicationrequest,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) ->
      Ok(any_delete(
        id,
        resources.RtCommunicationrequest,
        client,
        handle_response,
      ))
    None -> Error(ErrNoId)
  }
}

pub fn compartmentdefinition_create(
  resource: resources.Compartmentdefinition,
  client: FhirClient,
  handle_response: fn(Result(resources.Compartmentdefinition, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.compartmentdefinition_to_json(resource),
    resources.RtCompartmentdefinition,
    resources.compartmentdefinition_decoder(),
    client,
    handle_response,
  )
}

pub fn compartmentdefinition_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.Compartmentdefinition, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtCompartmentdefinition,
    resources.compartmentdefinition_decoder(),
    client,
    handle_response,
  )
}

pub fn compartmentdefinition_update(
  resource: resources.Compartmentdefinition,
  client: FhirClient,
  handle_response: fn(Result(resources.Compartmentdefinition, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.compartmentdefinition_to_json(resource),
    resources.RtCompartmentdefinition,
    resources.compartmentdefinition_decoder(),
    client,
    handle_response,
  )
}

pub fn compartmentdefinition_delete(
  resource: resources.Compartmentdefinition,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) ->
      Ok(any_delete(
        id,
        resources.RtCompartmentdefinition,
        client,
        handle_response,
      ))
    None -> Error(ErrNoId)
  }
}

pub fn composition_create(
  resource: resources.Composition,
  client: FhirClient,
  handle_response: fn(Result(resources.Composition, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.composition_to_json(resource),
    resources.RtComposition,
    resources.composition_decoder(),
    client,
    handle_response,
  )
}

pub fn composition_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.Composition, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtComposition,
    resources.composition_decoder(),
    client,
    handle_response,
  )
}

pub fn composition_update(
  resource: resources.Composition,
  client: FhirClient,
  handle_response: fn(Result(resources.Composition, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.composition_to_json(resource),
    resources.RtComposition,
    resources.composition_decoder(),
    client,
    handle_response,
  )
}

pub fn composition_delete(
  resource: resources.Composition,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) ->
      Ok(any_delete(id, resources.RtComposition, client, handle_response))
    None -> Error(ErrNoId)
  }
}

pub fn conceptmap_create(
  resource: resources.Conceptmap,
  client: FhirClient,
  handle_response: fn(Result(resources.Conceptmap, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.conceptmap_to_json(resource),
    resources.RtConceptmap,
    resources.conceptmap_decoder(),
    client,
    handle_response,
  )
}

pub fn conceptmap_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.Conceptmap, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtConceptmap,
    resources.conceptmap_decoder(),
    client,
    handle_response,
  )
}

pub fn conceptmap_update(
  resource: resources.Conceptmap,
  client: FhirClient,
  handle_response: fn(Result(resources.Conceptmap, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.conceptmap_to_json(resource),
    resources.RtConceptmap,
    resources.conceptmap_decoder(),
    client,
    handle_response,
  )
}

pub fn conceptmap_delete(
  resource: resources.Conceptmap,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) ->
      Ok(any_delete(id, resources.RtConceptmap, client, handle_response))
    None -> Error(ErrNoId)
  }
}

pub fn condition_create(
  resource: resources.Condition,
  client: FhirClient,
  handle_response: fn(Result(resources.Condition, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.condition_to_json(resource),
    resources.RtCondition,
    resources.condition_decoder(),
    client,
    handle_response,
  )
}

pub fn condition_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.Condition, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtCondition,
    resources.condition_decoder(),
    client,
    handle_response,
  )
}

pub fn condition_update(
  resource: resources.Condition,
  client: FhirClient,
  handle_response: fn(Result(resources.Condition, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.condition_to_json(resource),
    resources.RtCondition,
    resources.condition_decoder(),
    client,
    handle_response,
  )
}

pub fn condition_delete(
  resource: resources.Condition,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) ->
      Ok(any_delete(id, resources.RtCondition, client, handle_response))
    None -> Error(ErrNoId)
  }
}

pub fn conditiondefinition_create(
  resource: resources.Conditiondefinition,
  client: FhirClient,
  handle_response: fn(Result(resources.Conditiondefinition, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.conditiondefinition_to_json(resource),
    resources.RtConditiondefinition,
    resources.conditiondefinition_decoder(),
    client,
    handle_response,
  )
}

pub fn conditiondefinition_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.Conditiondefinition, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtConditiondefinition,
    resources.conditiondefinition_decoder(),
    client,
    handle_response,
  )
}

pub fn conditiondefinition_update(
  resource: resources.Conditiondefinition,
  client: FhirClient,
  handle_response: fn(Result(resources.Conditiondefinition, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.conditiondefinition_to_json(resource),
    resources.RtConditiondefinition,
    resources.conditiondefinition_decoder(),
    client,
    handle_response,
  )
}

pub fn conditiondefinition_delete(
  resource: resources.Conditiondefinition,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) ->
      Ok(any_delete(
        id,
        resources.RtConditiondefinition,
        client,
        handle_response,
      ))
    None -> Error(ErrNoId)
  }
}

pub fn consent_create(
  resource: resources.Consent,
  client: FhirClient,
  handle_response: fn(Result(resources.Consent, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.consent_to_json(resource),
    resources.RtConsent,
    resources.consent_decoder(),
    client,
    handle_response,
  )
}

pub fn consent_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.Consent, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtConsent,
    resources.consent_decoder(),
    client,
    handle_response,
  )
}

pub fn consent_update(
  resource: resources.Consent,
  client: FhirClient,
  handle_response: fn(Result(resources.Consent, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.consent_to_json(resource),
    resources.RtConsent,
    resources.consent_decoder(),
    client,
    handle_response,
  )
}

pub fn consent_delete(
  resource: resources.Consent,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) -> Ok(any_delete(id, resources.RtConsent, client, handle_response))
    None -> Error(ErrNoId)
  }
}

pub fn contract_create(
  resource: resources.Contract,
  client: FhirClient,
  handle_response: fn(Result(resources.Contract, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.contract_to_json(resource),
    resources.RtContract,
    resources.contract_decoder(),
    client,
    handle_response,
  )
}

pub fn contract_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.Contract, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtContract,
    resources.contract_decoder(),
    client,
    handle_response,
  )
}

pub fn contract_update(
  resource: resources.Contract,
  client: FhirClient,
  handle_response: fn(Result(resources.Contract, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.contract_to_json(resource),
    resources.RtContract,
    resources.contract_decoder(),
    client,
    handle_response,
  )
}

pub fn contract_delete(
  resource: resources.Contract,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) ->
      Ok(any_delete(id, resources.RtContract, client, handle_response))
    None -> Error(ErrNoId)
  }
}

pub fn coverage_create(
  resource: resources.Coverage,
  client: FhirClient,
  handle_response: fn(Result(resources.Coverage, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.coverage_to_json(resource),
    resources.RtCoverage,
    resources.coverage_decoder(),
    client,
    handle_response,
  )
}

pub fn coverage_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.Coverage, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtCoverage,
    resources.coverage_decoder(),
    client,
    handle_response,
  )
}

pub fn coverage_update(
  resource: resources.Coverage,
  client: FhirClient,
  handle_response: fn(Result(resources.Coverage, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.coverage_to_json(resource),
    resources.RtCoverage,
    resources.coverage_decoder(),
    client,
    handle_response,
  )
}

pub fn coverage_delete(
  resource: resources.Coverage,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) ->
      Ok(any_delete(id, resources.RtCoverage, client, handle_response))
    None -> Error(ErrNoId)
  }
}

pub fn coverageeligibilityrequest_create(
  resource: resources.Coverageeligibilityrequest,
  client: FhirClient,
  handle_response: fn(Result(resources.Coverageeligibilityrequest, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.coverageeligibilityrequest_to_json(resource),
    resources.RtCoverageeligibilityrequest,
    resources.coverageeligibilityrequest_decoder(),
    client,
    handle_response,
  )
}

pub fn coverageeligibilityrequest_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.Coverageeligibilityrequest, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtCoverageeligibilityrequest,
    resources.coverageeligibilityrequest_decoder(),
    client,
    handle_response,
  )
}

pub fn coverageeligibilityrequest_update(
  resource: resources.Coverageeligibilityrequest,
  client: FhirClient,
  handle_response: fn(Result(resources.Coverageeligibilityrequest, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.coverageeligibilityrequest_to_json(resource),
    resources.RtCoverageeligibilityrequest,
    resources.coverageeligibilityrequest_decoder(),
    client,
    handle_response,
  )
}

pub fn coverageeligibilityrequest_delete(
  resource: resources.Coverageeligibilityrequest,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) ->
      Ok(any_delete(
        id,
        resources.RtCoverageeligibilityrequest,
        client,
        handle_response,
      ))
    None -> Error(ErrNoId)
  }
}

pub fn coverageeligibilityresponse_create(
  resource: resources.Coverageeligibilityresponse,
  client: FhirClient,
  handle_response: fn(Result(resources.Coverageeligibilityresponse, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.coverageeligibilityresponse_to_json(resource),
    resources.RtCoverageeligibilityresponse,
    resources.coverageeligibilityresponse_decoder(),
    client,
    handle_response,
  )
}

pub fn coverageeligibilityresponse_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.Coverageeligibilityresponse, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtCoverageeligibilityresponse,
    resources.coverageeligibilityresponse_decoder(),
    client,
    handle_response,
  )
}

pub fn coverageeligibilityresponse_update(
  resource: resources.Coverageeligibilityresponse,
  client: FhirClient,
  handle_response: fn(Result(resources.Coverageeligibilityresponse, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.coverageeligibilityresponse_to_json(resource),
    resources.RtCoverageeligibilityresponse,
    resources.coverageeligibilityresponse_decoder(),
    client,
    handle_response,
  )
}

pub fn coverageeligibilityresponse_delete(
  resource: resources.Coverageeligibilityresponse,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) ->
      Ok(any_delete(
        id,
        resources.RtCoverageeligibilityresponse,
        client,
        handle_response,
      ))
    None -> Error(ErrNoId)
  }
}

pub fn detectedissue_create(
  resource: resources.Detectedissue,
  client: FhirClient,
  handle_response: fn(Result(resources.Detectedissue, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.detectedissue_to_json(resource),
    resources.RtDetectedissue,
    resources.detectedissue_decoder(),
    client,
    handle_response,
  )
}

pub fn detectedissue_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.Detectedissue, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtDetectedissue,
    resources.detectedissue_decoder(),
    client,
    handle_response,
  )
}

pub fn detectedissue_update(
  resource: resources.Detectedissue,
  client: FhirClient,
  handle_response: fn(Result(resources.Detectedissue, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.detectedissue_to_json(resource),
    resources.RtDetectedissue,
    resources.detectedissue_decoder(),
    client,
    handle_response,
  )
}

pub fn detectedissue_delete(
  resource: resources.Detectedissue,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) ->
      Ok(any_delete(id, resources.RtDetectedissue, client, handle_response))
    None -> Error(ErrNoId)
  }
}

pub fn device_create(
  resource: resources.Device,
  client: FhirClient,
  handle_response: fn(Result(resources.Device, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.device_to_json(resource),
    resources.RtDevice,
    resources.device_decoder(),
    client,
    handle_response,
  )
}

pub fn device_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.Device, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtDevice,
    resources.device_decoder(),
    client,
    handle_response,
  )
}

pub fn device_update(
  resource: resources.Device,
  client: FhirClient,
  handle_response: fn(Result(resources.Device, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.device_to_json(resource),
    resources.RtDevice,
    resources.device_decoder(),
    client,
    handle_response,
  )
}

pub fn device_delete(
  resource: resources.Device,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) -> Ok(any_delete(id, resources.RtDevice, client, handle_response))
    None -> Error(ErrNoId)
  }
}

pub fn deviceassociation_create(
  resource: resources.Deviceassociation,
  client: FhirClient,
  handle_response: fn(Result(resources.Deviceassociation, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.deviceassociation_to_json(resource),
    resources.RtDeviceassociation,
    resources.deviceassociation_decoder(),
    client,
    handle_response,
  )
}

pub fn deviceassociation_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.Deviceassociation, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtDeviceassociation,
    resources.deviceassociation_decoder(),
    client,
    handle_response,
  )
}

pub fn deviceassociation_update(
  resource: resources.Deviceassociation,
  client: FhirClient,
  handle_response: fn(Result(resources.Deviceassociation, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.deviceassociation_to_json(resource),
    resources.RtDeviceassociation,
    resources.deviceassociation_decoder(),
    client,
    handle_response,
  )
}

pub fn deviceassociation_delete(
  resource: resources.Deviceassociation,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) ->
      Ok(any_delete(id, resources.RtDeviceassociation, client, handle_response))
    None -> Error(ErrNoId)
  }
}

pub fn devicedefinition_create(
  resource: resources.Devicedefinition,
  client: FhirClient,
  handle_response: fn(Result(resources.Devicedefinition, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.devicedefinition_to_json(resource),
    resources.RtDevicedefinition,
    resources.devicedefinition_decoder(),
    client,
    handle_response,
  )
}

pub fn devicedefinition_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.Devicedefinition, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtDevicedefinition,
    resources.devicedefinition_decoder(),
    client,
    handle_response,
  )
}

pub fn devicedefinition_update(
  resource: resources.Devicedefinition,
  client: FhirClient,
  handle_response: fn(Result(resources.Devicedefinition, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.devicedefinition_to_json(resource),
    resources.RtDevicedefinition,
    resources.devicedefinition_decoder(),
    client,
    handle_response,
  )
}

pub fn devicedefinition_delete(
  resource: resources.Devicedefinition,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) ->
      Ok(any_delete(id, resources.RtDevicedefinition, client, handle_response))
    None -> Error(ErrNoId)
  }
}

pub fn devicedispense_create(
  resource: resources.Devicedispense,
  client: FhirClient,
  handle_response: fn(Result(resources.Devicedispense, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.devicedispense_to_json(resource),
    resources.RtDevicedispense,
    resources.devicedispense_decoder(),
    client,
    handle_response,
  )
}

pub fn devicedispense_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.Devicedispense, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtDevicedispense,
    resources.devicedispense_decoder(),
    client,
    handle_response,
  )
}

pub fn devicedispense_update(
  resource: resources.Devicedispense,
  client: FhirClient,
  handle_response: fn(Result(resources.Devicedispense, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.devicedispense_to_json(resource),
    resources.RtDevicedispense,
    resources.devicedispense_decoder(),
    client,
    handle_response,
  )
}

pub fn devicedispense_delete(
  resource: resources.Devicedispense,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) ->
      Ok(any_delete(id, resources.RtDevicedispense, client, handle_response))
    None -> Error(ErrNoId)
  }
}

pub fn devicemetric_create(
  resource: resources.Devicemetric,
  client: FhirClient,
  handle_response: fn(Result(resources.Devicemetric, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.devicemetric_to_json(resource),
    resources.RtDevicemetric,
    resources.devicemetric_decoder(),
    client,
    handle_response,
  )
}

pub fn devicemetric_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.Devicemetric, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtDevicemetric,
    resources.devicemetric_decoder(),
    client,
    handle_response,
  )
}

pub fn devicemetric_update(
  resource: resources.Devicemetric,
  client: FhirClient,
  handle_response: fn(Result(resources.Devicemetric, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.devicemetric_to_json(resource),
    resources.RtDevicemetric,
    resources.devicemetric_decoder(),
    client,
    handle_response,
  )
}

pub fn devicemetric_delete(
  resource: resources.Devicemetric,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) ->
      Ok(any_delete(id, resources.RtDevicemetric, client, handle_response))
    None -> Error(ErrNoId)
  }
}

pub fn devicerequest_create(
  resource: resources.Devicerequest,
  client: FhirClient,
  handle_response: fn(Result(resources.Devicerequest, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.devicerequest_to_json(resource),
    resources.RtDevicerequest,
    resources.devicerequest_decoder(),
    client,
    handle_response,
  )
}

pub fn devicerequest_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.Devicerequest, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtDevicerequest,
    resources.devicerequest_decoder(),
    client,
    handle_response,
  )
}

pub fn devicerequest_update(
  resource: resources.Devicerequest,
  client: FhirClient,
  handle_response: fn(Result(resources.Devicerequest, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.devicerequest_to_json(resource),
    resources.RtDevicerequest,
    resources.devicerequest_decoder(),
    client,
    handle_response,
  )
}

pub fn devicerequest_delete(
  resource: resources.Devicerequest,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) ->
      Ok(any_delete(id, resources.RtDevicerequest, client, handle_response))
    None -> Error(ErrNoId)
  }
}

pub fn deviceusage_create(
  resource: resources.Deviceusage,
  client: FhirClient,
  handle_response: fn(Result(resources.Deviceusage, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.deviceusage_to_json(resource),
    resources.RtDeviceusage,
    resources.deviceusage_decoder(),
    client,
    handle_response,
  )
}

pub fn deviceusage_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.Deviceusage, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtDeviceusage,
    resources.deviceusage_decoder(),
    client,
    handle_response,
  )
}

pub fn deviceusage_update(
  resource: resources.Deviceusage,
  client: FhirClient,
  handle_response: fn(Result(resources.Deviceusage, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.deviceusage_to_json(resource),
    resources.RtDeviceusage,
    resources.deviceusage_decoder(),
    client,
    handle_response,
  )
}

pub fn deviceusage_delete(
  resource: resources.Deviceusage,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) ->
      Ok(any_delete(id, resources.RtDeviceusage, client, handle_response))
    None -> Error(ErrNoId)
  }
}

pub fn diagnosticreport_create(
  resource: resources.Diagnosticreport,
  client: FhirClient,
  handle_response: fn(Result(resources.Diagnosticreport, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.diagnosticreport_to_json(resource),
    resources.RtDiagnosticreport,
    resources.diagnosticreport_decoder(),
    client,
    handle_response,
  )
}

pub fn diagnosticreport_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.Diagnosticreport, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtDiagnosticreport,
    resources.diagnosticreport_decoder(),
    client,
    handle_response,
  )
}

pub fn diagnosticreport_update(
  resource: resources.Diagnosticreport,
  client: FhirClient,
  handle_response: fn(Result(resources.Diagnosticreport, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.diagnosticreport_to_json(resource),
    resources.RtDiagnosticreport,
    resources.diagnosticreport_decoder(),
    client,
    handle_response,
  )
}

pub fn diagnosticreport_delete(
  resource: resources.Diagnosticreport,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) ->
      Ok(any_delete(id, resources.RtDiagnosticreport, client, handle_response))
    None -> Error(ErrNoId)
  }
}

pub fn documentreference_create(
  resource: resources.Documentreference,
  client: FhirClient,
  handle_response: fn(Result(resources.Documentreference, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.documentreference_to_json(resource),
    resources.RtDocumentreference,
    resources.documentreference_decoder(),
    client,
    handle_response,
  )
}

pub fn documentreference_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.Documentreference, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtDocumentreference,
    resources.documentreference_decoder(),
    client,
    handle_response,
  )
}

pub fn documentreference_update(
  resource: resources.Documentreference,
  client: FhirClient,
  handle_response: fn(Result(resources.Documentreference, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.documentreference_to_json(resource),
    resources.RtDocumentreference,
    resources.documentreference_decoder(),
    client,
    handle_response,
  )
}

pub fn documentreference_delete(
  resource: resources.Documentreference,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) ->
      Ok(any_delete(id, resources.RtDocumentreference, client, handle_response))
    None -> Error(ErrNoId)
  }
}

pub fn encounter_create(
  resource: resources.Encounter,
  client: FhirClient,
  handle_response: fn(Result(resources.Encounter, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.encounter_to_json(resource),
    resources.RtEncounter,
    resources.encounter_decoder(),
    client,
    handle_response,
  )
}

pub fn encounter_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.Encounter, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtEncounter,
    resources.encounter_decoder(),
    client,
    handle_response,
  )
}

pub fn encounter_update(
  resource: resources.Encounter,
  client: FhirClient,
  handle_response: fn(Result(resources.Encounter, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.encounter_to_json(resource),
    resources.RtEncounter,
    resources.encounter_decoder(),
    client,
    handle_response,
  )
}

pub fn encounter_delete(
  resource: resources.Encounter,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) ->
      Ok(any_delete(id, resources.RtEncounter, client, handle_response))
    None -> Error(ErrNoId)
  }
}

pub fn encounterhistory_create(
  resource: resources.Encounterhistory,
  client: FhirClient,
  handle_response: fn(Result(resources.Encounterhistory, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.encounterhistory_to_json(resource),
    resources.RtEncounterhistory,
    resources.encounterhistory_decoder(),
    client,
    handle_response,
  )
}

pub fn encounterhistory_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.Encounterhistory, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtEncounterhistory,
    resources.encounterhistory_decoder(),
    client,
    handle_response,
  )
}

pub fn encounterhistory_update(
  resource: resources.Encounterhistory,
  client: FhirClient,
  handle_response: fn(Result(resources.Encounterhistory, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.encounterhistory_to_json(resource),
    resources.RtEncounterhistory,
    resources.encounterhistory_decoder(),
    client,
    handle_response,
  )
}

pub fn encounterhistory_delete(
  resource: resources.Encounterhistory,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) ->
      Ok(any_delete(id, resources.RtEncounterhistory, client, handle_response))
    None -> Error(ErrNoId)
  }
}

pub fn endpoint_create(
  resource: resources.Endpoint,
  client: FhirClient,
  handle_response: fn(Result(resources.Endpoint, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.endpoint_to_json(resource),
    resources.RtEndpoint,
    resources.endpoint_decoder(),
    client,
    handle_response,
  )
}

pub fn endpoint_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.Endpoint, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtEndpoint,
    resources.endpoint_decoder(),
    client,
    handle_response,
  )
}

pub fn endpoint_update(
  resource: resources.Endpoint,
  client: FhirClient,
  handle_response: fn(Result(resources.Endpoint, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.endpoint_to_json(resource),
    resources.RtEndpoint,
    resources.endpoint_decoder(),
    client,
    handle_response,
  )
}

pub fn endpoint_delete(
  resource: resources.Endpoint,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) ->
      Ok(any_delete(id, resources.RtEndpoint, client, handle_response))
    None -> Error(ErrNoId)
  }
}

pub fn enrollmentrequest_create(
  resource: resources.Enrollmentrequest,
  client: FhirClient,
  handle_response: fn(Result(resources.Enrollmentrequest, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.enrollmentrequest_to_json(resource),
    resources.RtEnrollmentrequest,
    resources.enrollmentrequest_decoder(),
    client,
    handle_response,
  )
}

pub fn enrollmentrequest_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.Enrollmentrequest, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtEnrollmentrequest,
    resources.enrollmentrequest_decoder(),
    client,
    handle_response,
  )
}

pub fn enrollmentrequest_update(
  resource: resources.Enrollmentrequest,
  client: FhirClient,
  handle_response: fn(Result(resources.Enrollmentrequest, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.enrollmentrequest_to_json(resource),
    resources.RtEnrollmentrequest,
    resources.enrollmentrequest_decoder(),
    client,
    handle_response,
  )
}

pub fn enrollmentrequest_delete(
  resource: resources.Enrollmentrequest,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) ->
      Ok(any_delete(id, resources.RtEnrollmentrequest, client, handle_response))
    None -> Error(ErrNoId)
  }
}

pub fn enrollmentresponse_create(
  resource: resources.Enrollmentresponse,
  client: FhirClient,
  handle_response: fn(Result(resources.Enrollmentresponse, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.enrollmentresponse_to_json(resource),
    resources.RtEnrollmentresponse,
    resources.enrollmentresponse_decoder(),
    client,
    handle_response,
  )
}

pub fn enrollmentresponse_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.Enrollmentresponse, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtEnrollmentresponse,
    resources.enrollmentresponse_decoder(),
    client,
    handle_response,
  )
}

pub fn enrollmentresponse_update(
  resource: resources.Enrollmentresponse,
  client: FhirClient,
  handle_response: fn(Result(resources.Enrollmentresponse, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.enrollmentresponse_to_json(resource),
    resources.RtEnrollmentresponse,
    resources.enrollmentresponse_decoder(),
    client,
    handle_response,
  )
}

pub fn enrollmentresponse_delete(
  resource: resources.Enrollmentresponse,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) ->
      Ok(any_delete(id, resources.RtEnrollmentresponse, client, handle_response))
    None -> Error(ErrNoId)
  }
}

pub fn episodeofcare_create(
  resource: resources.Episodeofcare,
  client: FhirClient,
  handle_response: fn(Result(resources.Episodeofcare, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.episodeofcare_to_json(resource),
    resources.RtEpisodeofcare,
    resources.episodeofcare_decoder(),
    client,
    handle_response,
  )
}

pub fn episodeofcare_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.Episodeofcare, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtEpisodeofcare,
    resources.episodeofcare_decoder(),
    client,
    handle_response,
  )
}

pub fn episodeofcare_update(
  resource: resources.Episodeofcare,
  client: FhirClient,
  handle_response: fn(Result(resources.Episodeofcare, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.episodeofcare_to_json(resource),
    resources.RtEpisodeofcare,
    resources.episodeofcare_decoder(),
    client,
    handle_response,
  )
}

pub fn episodeofcare_delete(
  resource: resources.Episodeofcare,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) ->
      Ok(any_delete(id, resources.RtEpisodeofcare, client, handle_response))
    None -> Error(ErrNoId)
  }
}

pub fn eventdefinition_create(
  resource: resources.Eventdefinition,
  client: FhirClient,
  handle_response: fn(Result(resources.Eventdefinition, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.eventdefinition_to_json(resource),
    resources.RtEventdefinition,
    resources.eventdefinition_decoder(),
    client,
    handle_response,
  )
}

pub fn eventdefinition_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.Eventdefinition, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtEventdefinition,
    resources.eventdefinition_decoder(),
    client,
    handle_response,
  )
}

pub fn eventdefinition_update(
  resource: resources.Eventdefinition,
  client: FhirClient,
  handle_response: fn(Result(resources.Eventdefinition, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.eventdefinition_to_json(resource),
    resources.RtEventdefinition,
    resources.eventdefinition_decoder(),
    client,
    handle_response,
  )
}

pub fn eventdefinition_delete(
  resource: resources.Eventdefinition,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) ->
      Ok(any_delete(id, resources.RtEventdefinition, client, handle_response))
    None -> Error(ErrNoId)
  }
}

pub fn evidence_create(
  resource: resources.Evidence,
  client: FhirClient,
  handle_response: fn(Result(resources.Evidence, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.evidence_to_json(resource),
    resources.RtEvidence,
    resources.evidence_decoder(),
    client,
    handle_response,
  )
}

pub fn evidence_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.Evidence, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtEvidence,
    resources.evidence_decoder(),
    client,
    handle_response,
  )
}

pub fn evidence_update(
  resource: resources.Evidence,
  client: FhirClient,
  handle_response: fn(Result(resources.Evidence, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.evidence_to_json(resource),
    resources.RtEvidence,
    resources.evidence_decoder(),
    client,
    handle_response,
  )
}

pub fn evidence_delete(
  resource: resources.Evidence,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) ->
      Ok(any_delete(id, resources.RtEvidence, client, handle_response))
    None -> Error(ErrNoId)
  }
}

pub fn evidencereport_create(
  resource: resources.Evidencereport,
  client: FhirClient,
  handle_response: fn(Result(resources.Evidencereport, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.evidencereport_to_json(resource),
    resources.RtEvidencereport,
    resources.evidencereport_decoder(),
    client,
    handle_response,
  )
}

pub fn evidencereport_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.Evidencereport, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtEvidencereport,
    resources.evidencereport_decoder(),
    client,
    handle_response,
  )
}

pub fn evidencereport_update(
  resource: resources.Evidencereport,
  client: FhirClient,
  handle_response: fn(Result(resources.Evidencereport, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.evidencereport_to_json(resource),
    resources.RtEvidencereport,
    resources.evidencereport_decoder(),
    client,
    handle_response,
  )
}

pub fn evidencereport_delete(
  resource: resources.Evidencereport,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) ->
      Ok(any_delete(id, resources.RtEvidencereport, client, handle_response))
    None -> Error(ErrNoId)
  }
}

pub fn evidencevariable_create(
  resource: resources.Evidencevariable,
  client: FhirClient,
  handle_response: fn(Result(resources.Evidencevariable, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.evidencevariable_to_json(resource),
    resources.RtEvidencevariable,
    resources.evidencevariable_decoder(),
    client,
    handle_response,
  )
}

pub fn evidencevariable_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.Evidencevariable, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtEvidencevariable,
    resources.evidencevariable_decoder(),
    client,
    handle_response,
  )
}

pub fn evidencevariable_update(
  resource: resources.Evidencevariable,
  client: FhirClient,
  handle_response: fn(Result(resources.Evidencevariable, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.evidencevariable_to_json(resource),
    resources.RtEvidencevariable,
    resources.evidencevariable_decoder(),
    client,
    handle_response,
  )
}

pub fn evidencevariable_delete(
  resource: resources.Evidencevariable,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) ->
      Ok(any_delete(id, resources.RtEvidencevariable, client, handle_response))
    None -> Error(ErrNoId)
  }
}

pub fn examplescenario_create(
  resource: resources.Examplescenario,
  client: FhirClient,
  handle_response: fn(Result(resources.Examplescenario, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.examplescenario_to_json(resource),
    resources.RtExamplescenario,
    resources.examplescenario_decoder(),
    client,
    handle_response,
  )
}

pub fn examplescenario_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.Examplescenario, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtExamplescenario,
    resources.examplescenario_decoder(),
    client,
    handle_response,
  )
}

pub fn examplescenario_update(
  resource: resources.Examplescenario,
  client: FhirClient,
  handle_response: fn(Result(resources.Examplescenario, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.examplescenario_to_json(resource),
    resources.RtExamplescenario,
    resources.examplescenario_decoder(),
    client,
    handle_response,
  )
}

pub fn examplescenario_delete(
  resource: resources.Examplescenario,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) ->
      Ok(any_delete(id, resources.RtExamplescenario, client, handle_response))
    None -> Error(ErrNoId)
  }
}

pub fn explanationofbenefit_create(
  resource: resources.Explanationofbenefit,
  client: FhirClient,
  handle_response: fn(Result(resources.Explanationofbenefit, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.explanationofbenefit_to_json(resource),
    resources.RtExplanationofbenefit,
    resources.explanationofbenefit_decoder(),
    client,
    handle_response,
  )
}

pub fn explanationofbenefit_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.Explanationofbenefit, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtExplanationofbenefit,
    resources.explanationofbenefit_decoder(),
    client,
    handle_response,
  )
}

pub fn explanationofbenefit_update(
  resource: resources.Explanationofbenefit,
  client: FhirClient,
  handle_response: fn(Result(resources.Explanationofbenefit, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.explanationofbenefit_to_json(resource),
    resources.RtExplanationofbenefit,
    resources.explanationofbenefit_decoder(),
    client,
    handle_response,
  )
}

pub fn explanationofbenefit_delete(
  resource: resources.Explanationofbenefit,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) ->
      Ok(any_delete(
        id,
        resources.RtExplanationofbenefit,
        client,
        handle_response,
      ))
    None -> Error(ErrNoId)
  }
}

pub fn familymemberhistory_create(
  resource: resources.Familymemberhistory,
  client: FhirClient,
  handle_response: fn(Result(resources.Familymemberhistory, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.familymemberhistory_to_json(resource),
    resources.RtFamilymemberhistory,
    resources.familymemberhistory_decoder(),
    client,
    handle_response,
  )
}

pub fn familymemberhistory_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.Familymemberhistory, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtFamilymemberhistory,
    resources.familymemberhistory_decoder(),
    client,
    handle_response,
  )
}

pub fn familymemberhistory_update(
  resource: resources.Familymemberhistory,
  client: FhirClient,
  handle_response: fn(Result(resources.Familymemberhistory, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.familymemberhistory_to_json(resource),
    resources.RtFamilymemberhistory,
    resources.familymemberhistory_decoder(),
    client,
    handle_response,
  )
}

pub fn familymemberhistory_delete(
  resource: resources.Familymemberhistory,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) ->
      Ok(any_delete(
        id,
        resources.RtFamilymemberhistory,
        client,
        handle_response,
      ))
    None -> Error(ErrNoId)
  }
}

pub fn flag_create(
  resource: resources.Flag,
  client: FhirClient,
  handle_response: fn(Result(resources.Flag, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.flag_to_json(resource),
    resources.RtFlag,
    resources.flag_decoder(),
    client,
    handle_response,
  )
}

pub fn flag_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.Flag, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtFlag,
    resources.flag_decoder(),
    client,
    handle_response,
  )
}

pub fn flag_update(
  resource: resources.Flag,
  client: FhirClient,
  handle_response: fn(Result(resources.Flag, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.flag_to_json(resource),
    resources.RtFlag,
    resources.flag_decoder(),
    client,
    handle_response,
  )
}

pub fn flag_delete(
  resource: resources.Flag,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) -> Ok(any_delete(id, resources.RtFlag, client, handle_response))
    None -> Error(ErrNoId)
  }
}

pub fn formularyitem_create(
  resource: resources.Formularyitem,
  client: FhirClient,
  handle_response: fn(Result(resources.Formularyitem, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.formularyitem_to_json(resource),
    resources.RtFormularyitem,
    resources.formularyitem_decoder(),
    client,
    handle_response,
  )
}

pub fn formularyitem_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.Formularyitem, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtFormularyitem,
    resources.formularyitem_decoder(),
    client,
    handle_response,
  )
}

pub fn formularyitem_update(
  resource: resources.Formularyitem,
  client: FhirClient,
  handle_response: fn(Result(resources.Formularyitem, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.formularyitem_to_json(resource),
    resources.RtFormularyitem,
    resources.formularyitem_decoder(),
    client,
    handle_response,
  )
}

pub fn formularyitem_delete(
  resource: resources.Formularyitem,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) ->
      Ok(any_delete(id, resources.RtFormularyitem, client, handle_response))
    None -> Error(ErrNoId)
  }
}

pub fn genomicstudy_create(
  resource: resources.Genomicstudy,
  client: FhirClient,
  handle_response: fn(Result(resources.Genomicstudy, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.genomicstudy_to_json(resource),
    resources.RtGenomicstudy,
    resources.genomicstudy_decoder(),
    client,
    handle_response,
  )
}

pub fn genomicstudy_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.Genomicstudy, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtGenomicstudy,
    resources.genomicstudy_decoder(),
    client,
    handle_response,
  )
}

pub fn genomicstudy_update(
  resource: resources.Genomicstudy,
  client: FhirClient,
  handle_response: fn(Result(resources.Genomicstudy, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.genomicstudy_to_json(resource),
    resources.RtGenomicstudy,
    resources.genomicstudy_decoder(),
    client,
    handle_response,
  )
}

pub fn genomicstudy_delete(
  resource: resources.Genomicstudy,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) ->
      Ok(any_delete(id, resources.RtGenomicstudy, client, handle_response))
    None -> Error(ErrNoId)
  }
}

pub fn goal_create(
  resource: resources.Goal,
  client: FhirClient,
  handle_response: fn(Result(resources.Goal, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.goal_to_json(resource),
    resources.RtGoal,
    resources.goal_decoder(),
    client,
    handle_response,
  )
}

pub fn goal_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.Goal, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtGoal,
    resources.goal_decoder(),
    client,
    handle_response,
  )
}

pub fn goal_update(
  resource: resources.Goal,
  client: FhirClient,
  handle_response: fn(Result(resources.Goal, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.goal_to_json(resource),
    resources.RtGoal,
    resources.goal_decoder(),
    client,
    handle_response,
  )
}

pub fn goal_delete(
  resource: resources.Goal,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) -> Ok(any_delete(id, resources.RtGoal, client, handle_response))
    None -> Error(ErrNoId)
  }
}

pub fn graphdefinition_create(
  resource: resources.Graphdefinition,
  client: FhirClient,
  handle_response: fn(Result(resources.Graphdefinition, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.graphdefinition_to_json(resource),
    resources.RtGraphdefinition,
    resources.graphdefinition_decoder(),
    client,
    handle_response,
  )
}

pub fn graphdefinition_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.Graphdefinition, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtGraphdefinition,
    resources.graphdefinition_decoder(),
    client,
    handle_response,
  )
}

pub fn graphdefinition_update(
  resource: resources.Graphdefinition,
  client: FhirClient,
  handle_response: fn(Result(resources.Graphdefinition, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.graphdefinition_to_json(resource),
    resources.RtGraphdefinition,
    resources.graphdefinition_decoder(),
    client,
    handle_response,
  )
}

pub fn graphdefinition_delete(
  resource: resources.Graphdefinition,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) ->
      Ok(any_delete(id, resources.RtGraphdefinition, client, handle_response))
    None -> Error(ErrNoId)
  }
}

pub fn group_create(
  resource: resources.Group,
  client: FhirClient,
  handle_response: fn(Result(resources.Group, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.group_to_json(resource),
    resources.RtGroup,
    resources.group_decoder(),
    client,
    handle_response,
  )
}

pub fn group_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.Group, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtGroup,
    resources.group_decoder(),
    client,
    handle_response,
  )
}

pub fn group_update(
  resource: resources.Group,
  client: FhirClient,
  handle_response: fn(Result(resources.Group, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.group_to_json(resource),
    resources.RtGroup,
    resources.group_decoder(),
    client,
    handle_response,
  )
}

pub fn group_delete(
  resource: resources.Group,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) -> Ok(any_delete(id, resources.RtGroup, client, handle_response))
    None -> Error(ErrNoId)
  }
}

pub fn guidanceresponse_create(
  resource: resources.Guidanceresponse,
  client: FhirClient,
  handle_response: fn(Result(resources.Guidanceresponse, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.guidanceresponse_to_json(resource),
    resources.RtGuidanceresponse,
    resources.guidanceresponse_decoder(),
    client,
    handle_response,
  )
}

pub fn guidanceresponse_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.Guidanceresponse, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtGuidanceresponse,
    resources.guidanceresponse_decoder(),
    client,
    handle_response,
  )
}

pub fn guidanceresponse_update(
  resource: resources.Guidanceresponse,
  client: FhirClient,
  handle_response: fn(Result(resources.Guidanceresponse, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.guidanceresponse_to_json(resource),
    resources.RtGuidanceresponse,
    resources.guidanceresponse_decoder(),
    client,
    handle_response,
  )
}

pub fn guidanceresponse_delete(
  resource: resources.Guidanceresponse,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) ->
      Ok(any_delete(id, resources.RtGuidanceresponse, client, handle_response))
    None -> Error(ErrNoId)
  }
}

pub fn healthcareservice_create(
  resource: resources.Healthcareservice,
  client: FhirClient,
  handle_response: fn(Result(resources.Healthcareservice, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.healthcareservice_to_json(resource),
    resources.RtHealthcareservice,
    resources.healthcareservice_decoder(),
    client,
    handle_response,
  )
}

pub fn healthcareservice_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.Healthcareservice, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtHealthcareservice,
    resources.healthcareservice_decoder(),
    client,
    handle_response,
  )
}

pub fn healthcareservice_update(
  resource: resources.Healthcareservice,
  client: FhirClient,
  handle_response: fn(Result(resources.Healthcareservice, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.healthcareservice_to_json(resource),
    resources.RtHealthcareservice,
    resources.healthcareservice_decoder(),
    client,
    handle_response,
  )
}

pub fn healthcareservice_delete(
  resource: resources.Healthcareservice,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) ->
      Ok(any_delete(id, resources.RtHealthcareservice, client, handle_response))
    None -> Error(ErrNoId)
  }
}

pub fn imagingselection_create(
  resource: resources.Imagingselection,
  client: FhirClient,
  handle_response: fn(Result(resources.Imagingselection, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.imagingselection_to_json(resource),
    resources.RtImagingselection,
    resources.imagingselection_decoder(),
    client,
    handle_response,
  )
}

pub fn imagingselection_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.Imagingselection, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtImagingselection,
    resources.imagingselection_decoder(),
    client,
    handle_response,
  )
}

pub fn imagingselection_update(
  resource: resources.Imagingselection,
  client: FhirClient,
  handle_response: fn(Result(resources.Imagingselection, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.imagingselection_to_json(resource),
    resources.RtImagingselection,
    resources.imagingselection_decoder(),
    client,
    handle_response,
  )
}

pub fn imagingselection_delete(
  resource: resources.Imagingselection,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) ->
      Ok(any_delete(id, resources.RtImagingselection, client, handle_response))
    None -> Error(ErrNoId)
  }
}

pub fn imagingstudy_create(
  resource: resources.Imagingstudy,
  client: FhirClient,
  handle_response: fn(Result(resources.Imagingstudy, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.imagingstudy_to_json(resource),
    resources.RtImagingstudy,
    resources.imagingstudy_decoder(),
    client,
    handle_response,
  )
}

pub fn imagingstudy_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.Imagingstudy, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtImagingstudy,
    resources.imagingstudy_decoder(),
    client,
    handle_response,
  )
}

pub fn imagingstudy_update(
  resource: resources.Imagingstudy,
  client: FhirClient,
  handle_response: fn(Result(resources.Imagingstudy, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.imagingstudy_to_json(resource),
    resources.RtImagingstudy,
    resources.imagingstudy_decoder(),
    client,
    handle_response,
  )
}

pub fn imagingstudy_delete(
  resource: resources.Imagingstudy,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) ->
      Ok(any_delete(id, resources.RtImagingstudy, client, handle_response))
    None -> Error(ErrNoId)
  }
}

pub fn immunization_create(
  resource: resources.Immunization,
  client: FhirClient,
  handle_response: fn(Result(resources.Immunization, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.immunization_to_json(resource),
    resources.RtImmunization,
    resources.immunization_decoder(),
    client,
    handle_response,
  )
}

pub fn immunization_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.Immunization, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtImmunization,
    resources.immunization_decoder(),
    client,
    handle_response,
  )
}

pub fn immunization_update(
  resource: resources.Immunization,
  client: FhirClient,
  handle_response: fn(Result(resources.Immunization, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.immunization_to_json(resource),
    resources.RtImmunization,
    resources.immunization_decoder(),
    client,
    handle_response,
  )
}

pub fn immunization_delete(
  resource: resources.Immunization,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) ->
      Ok(any_delete(id, resources.RtImmunization, client, handle_response))
    None -> Error(ErrNoId)
  }
}

pub fn immunizationevaluation_create(
  resource: resources.Immunizationevaluation,
  client: FhirClient,
  handle_response: fn(Result(resources.Immunizationevaluation, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.immunizationevaluation_to_json(resource),
    resources.RtImmunizationevaluation,
    resources.immunizationevaluation_decoder(),
    client,
    handle_response,
  )
}

pub fn immunizationevaluation_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.Immunizationevaluation, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtImmunizationevaluation,
    resources.immunizationevaluation_decoder(),
    client,
    handle_response,
  )
}

pub fn immunizationevaluation_update(
  resource: resources.Immunizationevaluation,
  client: FhirClient,
  handle_response: fn(Result(resources.Immunizationevaluation, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.immunizationevaluation_to_json(resource),
    resources.RtImmunizationevaluation,
    resources.immunizationevaluation_decoder(),
    client,
    handle_response,
  )
}

pub fn immunizationevaluation_delete(
  resource: resources.Immunizationevaluation,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) ->
      Ok(any_delete(
        id,
        resources.RtImmunizationevaluation,
        client,
        handle_response,
      ))
    None -> Error(ErrNoId)
  }
}

pub fn immunizationrecommendation_create(
  resource: resources.Immunizationrecommendation,
  client: FhirClient,
  handle_response: fn(Result(resources.Immunizationrecommendation, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.immunizationrecommendation_to_json(resource),
    resources.RtImmunizationrecommendation,
    resources.immunizationrecommendation_decoder(),
    client,
    handle_response,
  )
}

pub fn immunizationrecommendation_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.Immunizationrecommendation, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtImmunizationrecommendation,
    resources.immunizationrecommendation_decoder(),
    client,
    handle_response,
  )
}

pub fn immunizationrecommendation_update(
  resource: resources.Immunizationrecommendation,
  client: FhirClient,
  handle_response: fn(Result(resources.Immunizationrecommendation, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.immunizationrecommendation_to_json(resource),
    resources.RtImmunizationrecommendation,
    resources.immunizationrecommendation_decoder(),
    client,
    handle_response,
  )
}

pub fn immunizationrecommendation_delete(
  resource: resources.Immunizationrecommendation,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) ->
      Ok(any_delete(
        id,
        resources.RtImmunizationrecommendation,
        client,
        handle_response,
      ))
    None -> Error(ErrNoId)
  }
}

pub fn implementationguide_create(
  resource: resources.Implementationguide,
  client: FhirClient,
  handle_response: fn(Result(resources.Implementationguide, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.implementationguide_to_json(resource),
    resources.RtImplementationguide,
    resources.implementationguide_decoder(),
    client,
    handle_response,
  )
}

pub fn implementationguide_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.Implementationguide, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtImplementationguide,
    resources.implementationguide_decoder(),
    client,
    handle_response,
  )
}

pub fn implementationguide_update(
  resource: resources.Implementationguide,
  client: FhirClient,
  handle_response: fn(Result(resources.Implementationguide, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.implementationguide_to_json(resource),
    resources.RtImplementationguide,
    resources.implementationguide_decoder(),
    client,
    handle_response,
  )
}

pub fn implementationguide_delete(
  resource: resources.Implementationguide,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) ->
      Ok(any_delete(
        id,
        resources.RtImplementationguide,
        client,
        handle_response,
      ))
    None -> Error(ErrNoId)
  }
}

pub fn ingredient_create(
  resource: resources.Ingredient,
  client: FhirClient,
  handle_response: fn(Result(resources.Ingredient, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.ingredient_to_json(resource),
    resources.RtIngredient,
    resources.ingredient_decoder(),
    client,
    handle_response,
  )
}

pub fn ingredient_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.Ingredient, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtIngredient,
    resources.ingredient_decoder(),
    client,
    handle_response,
  )
}

pub fn ingredient_update(
  resource: resources.Ingredient,
  client: FhirClient,
  handle_response: fn(Result(resources.Ingredient, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.ingredient_to_json(resource),
    resources.RtIngredient,
    resources.ingredient_decoder(),
    client,
    handle_response,
  )
}

pub fn ingredient_delete(
  resource: resources.Ingredient,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) ->
      Ok(any_delete(id, resources.RtIngredient, client, handle_response))
    None -> Error(ErrNoId)
  }
}

pub fn insuranceplan_create(
  resource: resources.Insuranceplan,
  client: FhirClient,
  handle_response: fn(Result(resources.Insuranceplan, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.insuranceplan_to_json(resource),
    resources.RtInsuranceplan,
    resources.insuranceplan_decoder(),
    client,
    handle_response,
  )
}

pub fn insuranceplan_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.Insuranceplan, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtInsuranceplan,
    resources.insuranceplan_decoder(),
    client,
    handle_response,
  )
}

pub fn insuranceplan_update(
  resource: resources.Insuranceplan,
  client: FhirClient,
  handle_response: fn(Result(resources.Insuranceplan, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.insuranceplan_to_json(resource),
    resources.RtInsuranceplan,
    resources.insuranceplan_decoder(),
    client,
    handle_response,
  )
}

pub fn insuranceplan_delete(
  resource: resources.Insuranceplan,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) ->
      Ok(any_delete(id, resources.RtInsuranceplan, client, handle_response))
    None -> Error(ErrNoId)
  }
}

pub fn inventoryitem_create(
  resource: resources.Inventoryitem,
  client: FhirClient,
  handle_response: fn(Result(resources.Inventoryitem, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.inventoryitem_to_json(resource),
    resources.RtInventoryitem,
    resources.inventoryitem_decoder(),
    client,
    handle_response,
  )
}

pub fn inventoryitem_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.Inventoryitem, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtInventoryitem,
    resources.inventoryitem_decoder(),
    client,
    handle_response,
  )
}

pub fn inventoryitem_update(
  resource: resources.Inventoryitem,
  client: FhirClient,
  handle_response: fn(Result(resources.Inventoryitem, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.inventoryitem_to_json(resource),
    resources.RtInventoryitem,
    resources.inventoryitem_decoder(),
    client,
    handle_response,
  )
}

pub fn inventoryitem_delete(
  resource: resources.Inventoryitem,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) ->
      Ok(any_delete(id, resources.RtInventoryitem, client, handle_response))
    None -> Error(ErrNoId)
  }
}

pub fn inventoryreport_create(
  resource: resources.Inventoryreport,
  client: FhirClient,
  handle_response: fn(Result(resources.Inventoryreport, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.inventoryreport_to_json(resource),
    resources.RtInventoryreport,
    resources.inventoryreport_decoder(),
    client,
    handle_response,
  )
}

pub fn inventoryreport_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.Inventoryreport, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtInventoryreport,
    resources.inventoryreport_decoder(),
    client,
    handle_response,
  )
}

pub fn inventoryreport_update(
  resource: resources.Inventoryreport,
  client: FhirClient,
  handle_response: fn(Result(resources.Inventoryreport, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.inventoryreport_to_json(resource),
    resources.RtInventoryreport,
    resources.inventoryreport_decoder(),
    client,
    handle_response,
  )
}

pub fn inventoryreport_delete(
  resource: resources.Inventoryreport,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) ->
      Ok(any_delete(id, resources.RtInventoryreport, client, handle_response))
    None -> Error(ErrNoId)
  }
}

pub fn invoice_create(
  resource: resources.Invoice,
  client: FhirClient,
  handle_response: fn(Result(resources.Invoice, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.invoice_to_json(resource),
    resources.RtInvoice,
    resources.invoice_decoder(),
    client,
    handle_response,
  )
}

pub fn invoice_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.Invoice, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtInvoice,
    resources.invoice_decoder(),
    client,
    handle_response,
  )
}

pub fn invoice_update(
  resource: resources.Invoice,
  client: FhirClient,
  handle_response: fn(Result(resources.Invoice, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.invoice_to_json(resource),
    resources.RtInvoice,
    resources.invoice_decoder(),
    client,
    handle_response,
  )
}

pub fn invoice_delete(
  resource: resources.Invoice,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) -> Ok(any_delete(id, resources.RtInvoice, client, handle_response))
    None -> Error(ErrNoId)
  }
}

pub fn library_create(
  resource: resources.Library,
  client: FhirClient,
  handle_response: fn(Result(resources.Library, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.library_to_json(resource),
    resources.RtLibrary,
    resources.library_decoder(),
    client,
    handle_response,
  )
}

pub fn library_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.Library, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtLibrary,
    resources.library_decoder(),
    client,
    handle_response,
  )
}

pub fn library_update(
  resource: resources.Library,
  client: FhirClient,
  handle_response: fn(Result(resources.Library, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.library_to_json(resource),
    resources.RtLibrary,
    resources.library_decoder(),
    client,
    handle_response,
  )
}

pub fn library_delete(
  resource: resources.Library,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) -> Ok(any_delete(id, resources.RtLibrary, client, handle_response))
    None -> Error(ErrNoId)
  }
}

pub fn linkage_create(
  resource: resources.Linkage,
  client: FhirClient,
  handle_response: fn(Result(resources.Linkage, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.linkage_to_json(resource),
    resources.RtLinkage,
    resources.linkage_decoder(),
    client,
    handle_response,
  )
}

pub fn linkage_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.Linkage, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtLinkage,
    resources.linkage_decoder(),
    client,
    handle_response,
  )
}

pub fn linkage_update(
  resource: resources.Linkage,
  client: FhirClient,
  handle_response: fn(Result(resources.Linkage, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.linkage_to_json(resource),
    resources.RtLinkage,
    resources.linkage_decoder(),
    client,
    handle_response,
  )
}

pub fn linkage_delete(
  resource: resources.Linkage,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) -> Ok(any_delete(id, resources.RtLinkage, client, handle_response))
    None -> Error(ErrNoId)
  }
}

pub fn listfhir_create(
  resource: resources.Listfhir,
  client: FhirClient,
  handle_response: fn(Result(resources.Listfhir, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.listfhir_to_json(resource),
    resources.RtListfhir,
    resources.listfhir_decoder(),
    client,
    handle_response,
  )
}

pub fn listfhir_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.Listfhir, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtListfhir,
    resources.listfhir_decoder(),
    client,
    handle_response,
  )
}

pub fn listfhir_update(
  resource: resources.Listfhir,
  client: FhirClient,
  handle_response: fn(Result(resources.Listfhir, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.listfhir_to_json(resource),
    resources.RtListfhir,
    resources.listfhir_decoder(),
    client,
    handle_response,
  )
}

pub fn listfhir_delete(
  resource: resources.Listfhir,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) ->
      Ok(any_delete(id, resources.RtListfhir, client, handle_response))
    None -> Error(ErrNoId)
  }
}

pub fn location_create(
  resource: resources.Location,
  client: FhirClient,
  handle_response: fn(Result(resources.Location, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.location_to_json(resource),
    resources.RtLocation,
    resources.location_decoder(),
    client,
    handle_response,
  )
}

pub fn location_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.Location, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtLocation,
    resources.location_decoder(),
    client,
    handle_response,
  )
}

pub fn location_update(
  resource: resources.Location,
  client: FhirClient,
  handle_response: fn(Result(resources.Location, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.location_to_json(resource),
    resources.RtLocation,
    resources.location_decoder(),
    client,
    handle_response,
  )
}

pub fn location_delete(
  resource: resources.Location,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) ->
      Ok(any_delete(id, resources.RtLocation, client, handle_response))
    None -> Error(ErrNoId)
  }
}

pub fn manufactureditemdefinition_create(
  resource: resources.Manufactureditemdefinition,
  client: FhirClient,
  handle_response: fn(Result(resources.Manufactureditemdefinition, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.manufactureditemdefinition_to_json(resource),
    resources.RtManufactureditemdefinition,
    resources.manufactureditemdefinition_decoder(),
    client,
    handle_response,
  )
}

pub fn manufactureditemdefinition_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.Manufactureditemdefinition, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtManufactureditemdefinition,
    resources.manufactureditemdefinition_decoder(),
    client,
    handle_response,
  )
}

pub fn manufactureditemdefinition_update(
  resource: resources.Manufactureditemdefinition,
  client: FhirClient,
  handle_response: fn(Result(resources.Manufactureditemdefinition, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.manufactureditemdefinition_to_json(resource),
    resources.RtManufactureditemdefinition,
    resources.manufactureditemdefinition_decoder(),
    client,
    handle_response,
  )
}

pub fn manufactureditemdefinition_delete(
  resource: resources.Manufactureditemdefinition,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) ->
      Ok(any_delete(
        id,
        resources.RtManufactureditemdefinition,
        client,
        handle_response,
      ))
    None -> Error(ErrNoId)
  }
}

pub fn measure_create(
  resource: resources.Measure,
  client: FhirClient,
  handle_response: fn(Result(resources.Measure, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.measure_to_json(resource),
    resources.RtMeasure,
    resources.measure_decoder(),
    client,
    handle_response,
  )
}

pub fn measure_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.Measure, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtMeasure,
    resources.measure_decoder(),
    client,
    handle_response,
  )
}

pub fn measure_update(
  resource: resources.Measure,
  client: FhirClient,
  handle_response: fn(Result(resources.Measure, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.measure_to_json(resource),
    resources.RtMeasure,
    resources.measure_decoder(),
    client,
    handle_response,
  )
}

pub fn measure_delete(
  resource: resources.Measure,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) -> Ok(any_delete(id, resources.RtMeasure, client, handle_response))
    None -> Error(ErrNoId)
  }
}

pub fn measurereport_create(
  resource: resources.Measurereport,
  client: FhirClient,
  handle_response: fn(Result(resources.Measurereport, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.measurereport_to_json(resource),
    resources.RtMeasurereport,
    resources.measurereport_decoder(),
    client,
    handle_response,
  )
}

pub fn measurereport_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.Measurereport, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtMeasurereport,
    resources.measurereport_decoder(),
    client,
    handle_response,
  )
}

pub fn measurereport_update(
  resource: resources.Measurereport,
  client: FhirClient,
  handle_response: fn(Result(resources.Measurereport, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.measurereport_to_json(resource),
    resources.RtMeasurereport,
    resources.measurereport_decoder(),
    client,
    handle_response,
  )
}

pub fn measurereport_delete(
  resource: resources.Measurereport,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) ->
      Ok(any_delete(id, resources.RtMeasurereport, client, handle_response))
    None -> Error(ErrNoId)
  }
}

pub fn medication_create(
  resource: resources.Medication,
  client: FhirClient,
  handle_response: fn(Result(resources.Medication, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.medication_to_json(resource),
    resources.RtMedication,
    resources.medication_decoder(),
    client,
    handle_response,
  )
}

pub fn medication_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.Medication, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtMedication,
    resources.medication_decoder(),
    client,
    handle_response,
  )
}

pub fn medication_update(
  resource: resources.Medication,
  client: FhirClient,
  handle_response: fn(Result(resources.Medication, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.medication_to_json(resource),
    resources.RtMedication,
    resources.medication_decoder(),
    client,
    handle_response,
  )
}

pub fn medication_delete(
  resource: resources.Medication,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) ->
      Ok(any_delete(id, resources.RtMedication, client, handle_response))
    None -> Error(ErrNoId)
  }
}

pub fn medicationadministration_create(
  resource: resources.Medicationadministration,
  client: FhirClient,
  handle_response: fn(Result(resources.Medicationadministration, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.medicationadministration_to_json(resource),
    resources.RtMedicationadministration,
    resources.medicationadministration_decoder(),
    client,
    handle_response,
  )
}

pub fn medicationadministration_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.Medicationadministration, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtMedicationadministration,
    resources.medicationadministration_decoder(),
    client,
    handle_response,
  )
}

pub fn medicationadministration_update(
  resource: resources.Medicationadministration,
  client: FhirClient,
  handle_response: fn(Result(resources.Medicationadministration, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.medicationadministration_to_json(resource),
    resources.RtMedicationadministration,
    resources.medicationadministration_decoder(),
    client,
    handle_response,
  )
}

pub fn medicationadministration_delete(
  resource: resources.Medicationadministration,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) ->
      Ok(any_delete(
        id,
        resources.RtMedicationadministration,
        client,
        handle_response,
      ))
    None -> Error(ErrNoId)
  }
}

pub fn medicationdispense_create(
  resource: resources.Medicationdispense,
  client: FhirClient,
  handle_response: fn(Result(resources.Medicationdispense, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.medicationdispense_to_json(resource),
    resources.RtMedicationdispense,
    resources.medicationdispense_decoder(),
    client,
    handle_response,
  )
}

pub fn medicationdispense_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.Medicationdispense, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtMedicationdispense,
    resources.medicationdispense_decoder(),
    client,
    handle_response,
  )
}

pub fn medicationdispense_update(
  resource: resources.Medicationdispense,
  client: FhirClient,
  handle_response: fn(Result(resources.Medicationdispense, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.medicationdispense_to_json(resource),
    resources.RtMedicationdispense,
    resources.medicationdispense_decoder(),
    client,
    handle_response,
  )
}

pub fn medicationdispense_delete(
  resource: resources.Medicationdispense,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) ->
      Ok(any_delete(id, resources.RtMedicationdispense, client, handle_response))
    None -> Error(ErrNoId)
  }
}

pub fn medicationknowledge_create(
  resource: resources.Medicationknowledge,
  client: FhirClient,
  handle_response: fn(Result(resources.Medicationknowledge, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.medicationknowledge_to_json(resource),
    resources.RtMedicationknowledge,
    resources.medicationknowledge_decoder(),
    client,
    handle_response,
  )
}

pub fn medicationknowledge_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.Medicationknowledge, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtMedicationknowledge,
    resources.medicationknowledge_decoder(),
    client,
    handle_response,
  )
}

pub fn medicationknowledge_update(
  resource: resources.Medicationknowledge,
  client: FhirClient,
  handle_response: fn(Result(resources.Medicationknowledge, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.medicationknowledge_to_json(resource),
    resources.RtMedicationknowledge,
    resources.medicationknowledge_decoder(),
    client,
    handle_response,
  )
}

pub fn medicationknowledge_delete(
  resource: resources.Medicationknowledge,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) ->
      Ok(any_delete(
        id,
        resources.RtMedicationknowledge,
        client,
        handle_response,
      ))
    None -> Error(ErrNoId)
  }
}

pub fn medicationrequest_create(
  resource: resources.Medicationrequest,
  client: FhirClient,
  handle_response: fn(Result(resources.Medicationrequest, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.medicationrequest_to_json(resource),
    resources.RtMedicationrequest,
    resources.medicationrequest_decoder(),
    client,
    handle_response,
  )
}

pub fn medicationrequest_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.Medicationrequest, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtMedicationrequest,
    resources.medicationrequest_decoder(),
    client,
    handle_response,
  )
}

pub fn medicationrequest_update(
  resource: resources.Medicationrequest,
  client: FhirClient,
  handle_response: fn(Result(resources.Medicationrequest, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.medicationrequest_to_json(resource),
    resources.RtMedicationrequest,
    resources.medicationrequest_decoder(),
    client,
    handle_response,
  )
}

pub fn medicationrequest_delete(
  resource: resources.Medicationrequest,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) ->
      Ok(any_delete(id, resources.RtMedicationrequest, client, handle_response))
    None -> Error(ErrNoId)
  }
}

pub fn medicationstatement_create(
  resource: resources.Medicationstatement,
  client: FhirClient,
  handle_response: fn(Result(resources.Medicationstatement, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.medicationstatement_to_json(resource),
    resources.RtMedicationstatement,
    resources.medicationstatement_decoder(),
    client,
    handle_response,
  )
}

pub fn medicationstatement_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.Medicationstatement, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtMedicationstatement,
    resources.medicationstatement_decoder(),
    client,
    handle_response,
  )
}

pub fn medicationstatement_update(
  resource: resources.Medicationstatement,
  client: FhirClient,
  handle_response: fn(Result(resources.Medicationstatement, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.medicationstatement_to_json(resource),
    resources.RtMedicationstatement,
    resources.medicationstatement_decoder(),
    client,
    handle_response,
  )
}

pub fn medicationstatement_delete(
  resource: resources.Medicationstatement,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) ->
      Ok(any_delete(
        id,
        resources.RtMedicationstatement,
        client,
        handle_response,
      ))
    None -> Error(ErrNoId)
  }
}

pub fn medicinalproductdefinition_create(
  resource: resources.Medicinalproductdefinition,
  client: FhirClient,
  handle_response: fn(Result(resources.Medicinalproductdefinition, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.medicinalproductdefinition_to_json(resource),
    resources.RtMedicinalproductdefinition,
    resources.medicinalproductdefinition_decoder(),
    client,
    handle_response,
  )
}

pub fn medicinalproductdefinition_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.Medicinalproductdefinition, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtMedicinalproductdefinition,
    resources.medicinalproductdefinition_decoder(),
    client,
    handle_response,
  )
}

pub fn medicinalproductdefinition_update(
  resource: resources.Medicinalproductdefinition,
  client: FhirClient,
  handle_response: fn(Result(resources.Medicinalproductdefinition, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.medicinalproductdefinition_to_json(resource),
    resources.RtMedicinalproductdefinition,
    resources.medicinalproductdefinition_decoder(),
    client,
    handle_response,
  )
}

pub fn medicinalproductdefinition_delete(
  resource: resources.Medicinalproductdefinition,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) ->
      Ok(any_delete(
        id,
        resources.RtMedicinalproductdefinition,
        client,
        handle_response,
      ))
    None -> Error(ErrNoId)
  }
}

pub fn messagedefinition_create(
  resource: resources.Messagedefinition,
  client: FhirClient,
  handle_response: fn(Result(resources.Messagedefinition, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.messagedefinition_to_json(resource),
    resources.RtMessagedefinition,
    resources.messagedefinition_decoder(),
    client,
    handle_response,
  )
}

pub fn messagedefinition_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.Messagedefinition, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtMessagedefinition,
    resources.messagedefinition_decoder(),
    client,
    handle_response,
  )
}

pub fn messagedefinition_update(
  resource: resources.Messagedefinition,
  client: FhirClient,
  handle_response: fn(Result(resources.Messagedefinition, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.messagedefinition_to_json(resource),
    resources.RtMessagedefinition,
    resources.messagedefinition_decoder(),
    client,
    handle_response,
  )
}

pub fn messagedefinition_delete(
  resource: resources.Messagedefinition,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) ->
      Ok(any_delete(id, resources.RtMessagedefinition, client, handle_response))
    None -> Error(ErrNoId)
  }
}

pub fn messageheader_create(
  resource: resources.Messageheader,
  client: FhirClient,
  handle_response: fn(Result(resources.Messageheader, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.messageheader_to_json(resource),
    resources.RtMessageheader,
    resources.messageheader_decoder(),
    client,
    handle_response,
  )
}

pub fn messageheader_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.Messageheader, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtMessageheader,
    resources.messageheader_decoder(),
    client,
    handle_response,
  )
}

pub fn messageheader_update(
  resource: resources.Messageheader,
  client: FhirClient,
  handle_response: fn(Result(resources.Messageheader, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.messageheader_to_json(resource),
    resources.RtMessageheader,
    resources.messageheader_decoder(),
    client,
    handle_response,
  )
}

pub fn messageheader_delete(
  resource: resources.Messageheader,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) ->
      Ok(any_delete(id, resources.RtMessageheader, client, handle_response))
    None -> Error(ErrNoId)
  }
}

pub fn molecularsequence_create(
  resource: resources.Molecularsequence,
  client: FhirClient,
  handle_response: fn(Result(resources.Molecularsequence, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.molecularsequence_to_json(resource),
    resources.RtMolecularsequence,
    resources.molecularsequence_decoder(),
    client,
    handle_response,
  )
}

pub fn molecularsequence_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.Molecularsequence, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtMolecularsequence,
    resources.molecularsequence_decoder(),
    client,
    handle_response,
  )
}

pub fn molecularsequence_update(
  resource: resources.Molecularsequence,
  client: FhirClient,
  handle_response: fn(Result(resources.Molecularsequence, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.molecularsequence_to_json(resource),
    resources.RtMolecularsequence,
    resources.molecularsequence_decoder(),
    client,
    handle_response,
  )
}

pub fn molecularsequence_delete(
  resource: resources.Molecularsequence,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) ->
      Ok(any_delete(id, resources.RtMolecularsequence, client, handle_response))
    None -> Error(ErrNoId)
  }
}

pub fn namingsystem_create(
  resource: resources.Namingsystem,
  client: FhirClient,
  handle_response: fn(Result(resources.Namingsystem, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.namingsystem_to_json(resource),
    resources.RtNamingsystem,
    resources.namingsystem_decoder(),
    client,
    handle_response,
  )
}

pub fn namingsystem_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.Namingsystem, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtNamingsystem,
    resources.namingsystem_decoder(),
    client,
    handle_response,
  )
}

pub fn namingsystem_update(
  resource: resources.Namingsystem,
  client: FhirClient,
  handle_response: fn(Result(resources.Namingsystem, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.namingsystem_to_json(resource),
    resources.RtNamingsystem,
    resources.namingsystem_decoder(),
    client,
    handle_response,
  )
}

pub fn namingsystem_delete(
  resource: resources.Namingsystem,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) ->
      Ok(any_delete(id, resources.RtNamingsystem, client, handle_response))
    None -> Error(ErrNoId)
  }
}

pub fn nutritionintake_create(
  resource: resources.Nutritionintake,
  client: FhirClient,
  handle_response: fn(Result(resources.Nutritionintake, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.nutritionintake_to_json(resource),
    resources.RtNutritionintake,
    resources.nutritionintake_decoder(),
    client,
    handle_response,
  )
}

pub fn nutritionintake_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.Nutritionintake, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtNutritionintake,
    resources.nutritionintake_decoder(),
    client,
    handle_response,
  )
}

pub fn nutritionintake_update(
  resource: resources.Nutritionintake,
  client: FhirClient,
  handle_response: fn(Result(resources.Nutritionintake, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.nutritionintake_to_json(resource),
    resources.RtNutritionintake,
    resources.nutritionintake_decoder(),
    client,
    handle_response,
  )
}

pub fn nutritionintake_delete(
  resource: resources.Nutritionintake,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) ->
      Ok(any_delete(id, resources.RtNutritionintake, client, handle_response))
    None -> Error(ErrNoId)
  }
}

pub fn nutritionorder_create(
  resource: resources.Nutritionorder,
  client: FhirClient,
  handle_response: fn(Result(resources.Nutritionorder, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.nutritionorder_to_json(resource),
    resources.RtNutritionorder,
    resources.nutritionorder_decoder(),
    client,
    handle_response,
  )
}

pub fn nutritionorder_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.Nutritionorder, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtNutritionorder,
    resources.nutritionorder_decoder(),
    client,
    handle_response,
  )
}

pub fn nutritionorder_update(
  resource: resources.Nutritionorder,
  client: FhirClient,
  handle_response: fn(Result(resources.Nutritionorder, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.nutritionorder_to_json(resource),
    resources.RtNutritionorder,
    resources.nutritionorder_decoder(),
    client,
    handle_response,
  )
}

pub fn nutritionorder_delete(
  resource: resources.Nutritionorder,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) ->
      Ok(any_delete(id, resources.RtNutritionorder, client, handle_response))
    None -> Error(ErrNoId)
  }
}

pub fn nutritionproduct_create(
  resource: resources.Nutritionproduct,
  client: FhirClient,
  handle_response: fn(Result(resources.Nutritionproduct, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.nutritionproduct_to_json(resource),
    resources.RtNutritionproduct,
    resources.nutritionproduct_decoder(),
    client,
    handle_response,
  )
}

pub fn nutritionproduct_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.Nutritionproduct, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtNutritionproduct,
    resources.nutritionproduct_decoder(),
    client,
    handle_response,
  )
}

pub fn nutritionproduct_update(
  resource: resources.Nutritionproduct,
  client: FhirClient,
  handle_response: fn(Result(resources.Nutritionproduct, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.nutritionproduct_to_json(resource),
    resources.RtNutritionproduct,
    resources.nutritionproduct_decoder(),
    client,
    handle_response,
  )
}

pub fn nutritionproduct_delete(
  resource: resources.Nutritionproduct,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) ->
      Ok(any_delete(id, resources.RtNutritionproduct, client, handle_response))
    None -> Error(ErrNoId)
  }
}

pub fn observation_create(
  resource: resources.Observation,
  client: FhirClient,
  handle_response: fn(Result(resources.Observation, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.observation_to_json(resource),
    resources.RtObservation,
    resources.observation_decoder(),
    client,
    handle_response,
  )
}

pub fn observation_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.Observation, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtObservation,
    resources.observation_decoder(),
    client,
    handle_response,
  )
}

pub fn observation_update(
  resource: resources.Observation,
  client: FhirClient,
  handle_response: fn(Result(resources.Observation, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.observation_to_json(resource),
    resources.RtObservation,
    resources.observation_decoder(),
    client,
    handle_response,
  )
}

pub fn observation_delete(
  resource: resources.Observation,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) ->
      Ok(any_delete(id, resources.RtObservation, client, handle_response))
    None -> Error(ErrNoId)
  }
}

pub fn observationdefinition_create(
  resource: resources.Observationdefinition,
  client: FhirClient,
  handle_response: fn(Result(resources.Observationdefinition, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.observationdefinition_to_json(resource),
    resources.RtObservationdefinition,
    resources.observationdefinition_decoder(),
    client,
    handle_response,
  )
}

pub fn observationdefinition_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.Observationdefinition, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtObservationdefinition,
    resources.observationdefinition_decoder(),
    client,
    handle_response,
  )
}

pub fn observationdefinition_update(
  resource: resources.Observationdefinition,
  client: FhirClient,
  handle_response: fn(Result(resources.Observationdefinition, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.observationdefinition_to_json(resource),
    resources.RtObservationdefinition,
    resources.observationdefinition_decoder(),
    client,
    handle_response,
  )
}

pub fn observationdefinition_delete(
  resource: resources.Observationdefinition,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) ->
      Ok(any_delete(
        id,
        resources.RtObservationdefinition,
        client,
        handle_response,
      ))
    None -> Error(ErrNoId)
  }
}

pub fn operationdefinition_create(
  resource: resources.Operationdefinition,
  client: FhirClient,
  handle_response: fn(Result(resources.Operationdefinition, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.operationdefinition_to_json(resource),
    resources.RtOperationdefinition,
    resources.operationdefinition_decoder(),
    client,
    handle_response,
  )
}

pub fn operationdefinition_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.Operationdefinition, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtOperationdefinition,
    resources.operationdefinition_decoder(),
    client,
    handle_response,
  )
}

pub fn operationdefinition_update(
  resource: resources.Operationdefinition,
  client: FhirClient,
  handle_response: fn(Result(resources.Operationdefinition, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.operationdefinition_to_json(resource),
    resources.RtOperationdefinition,
    resources.operationdefinition_decoder(),
    client,
    handle_response,
  )
}

pub fn operationdefinition_delete(
  resource: resources.Operationdefinition,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) ->
      Ok(any_delete(
        id,
        resources.RtOperationdefinition,
        client,
        handle_response,
      ))
    None -> Error(ErrNoId)
  }
}

pub fn operationoutcome_create(
  resource: resources.Operationoutcome,
  client: FhirClient,
  handle_response: fn(Result(resources.Operationoutcome, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.operationoutcome_to_json(resource),
    resources.RtOperationoutcome,
    resources.operationoutcome_decoder(),
    client,
    handle_response,
  )
}

pub fn operationoutcome_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.Operationoutcome, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtOperationoutcome,
    resources.operationoutcome_decoder(),
    client,
    handle_response,
  )
}

pub fn operationoutcome_update(
  resource: resources.Operationoutcome,
  client: FhirClient,
  handle_response: fn(Result(resources.Operationoutcome, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.operationoutcome_to_json(resource),
    resources.RtOperationoutcome,
    resources.operationoutcome_decoder(),
    client,
    handle_response,
  )
}

pub fn operationoutcome_delete(
  resource: resources.Operationoutcome,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) ->
      Ok(any_delete(id, resources.RtOperationoutcome, client, handle_response))
    None -> Error(ErrNoId)
  }
}

pub fn organization_create(
  resource: resources.Organization,
  client: FhirClient,
  handle_response: fn(Result(resources.Organization, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.organization_to_json(resource),
    resources.RtOrganization,
    resources.organization_decoder(),
    client,
    handle_response,
  )
}

pub fn organization_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.Organization, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtOrganization,
    resources.organization_decoder(),
    client,
    handle_response,
  )
}

pub fn organization_update(
  resource: resources.Organization,
  client: FhirClient,
  handle_response: fn(Result(resources.Organization, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.organization_to_json(resource),
    resources.RtOrganization,
    resources.organization_decoder(),
    client,
    handle_response,
  )
}

pub fn organization_delete(
  resource: resources.Organization,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) ->
      Ok(any_delete(id, resources.RtOrganization, client, handle_response))
    None -> Error(ErrNoId)
  }
}

pub fn organizationaffiliation_create(
  resource: resources.Organizationaffiliation,
  client: FhirClient,
  handle_response: fn(Result(resources.Organizationaffiliation, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.organizationaffiliation_to_json(resource),
    resources.RtOrganizationaffiliation,
    resources.organizationaffiliation_decoder(),
    client,
    handle_response,
  )
}

pub fn organizationaffiliation_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.Organizationaffiliation, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtOrganizationaffiliation,
    resources.organizationaffiliation_decoder(),
    client,
    handle_response,
  )
}

pub fn organizationaffiliation_update(
  resource: resources.Organizationaffiliation,
  client: FhirClient,
  handle_response: fn(Result(resources.Organizationaffiliation, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.organizationaffiliation_to_json(resource),
    resources.RtOrganizationaffiliation,
    resources.organizationaffiliation_decoder(),
    client,
    handle_response,
  )
}

pub fn organizationaffiliation_delete(
  resource: resources.Organizationaffiliation,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) ->
      Ok(any_delete(
        id,
        resources.RtOrganizationaffiliation,
        client,
        handle_response,
      ))
    None -> Error(ErrNoId)
  }
}

pub fn packagedproductdefinition_create(
  resource: resources.Packagedproductdefinition,
  client: FhirClient,
  handle_response: fn(Result(resources.Packagedproductdefinition, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.packagedproductdefinition_to_json(resource),
    resources.RtPackagedproductdefinition,
    resources.packagedproductdefinition_decoder(),
    client,
    handle_response,
  )
}

pub fn packagedproductdefinition_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.Packagedproductdefinition, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtPackagedproductdefinition,
    resources.packagedproductdefinition_decoder(),
    client,
    handle_response,
  )
}

pub fn packagedproductdefinition_update(
  resource: resources.Packagedproductdefinition,
  client: FhirClient,
  handle_response: fn(Result(resources.Packagedproductdefinition, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.packagedproductdefinition_to_json(resource),
    resources.RtPackagedproductdefinition,
    resources.packagedproductdefinition_decoder(),
    client,
    handle_response,
  )
}

pub fn packagedproductdefinition_delete(
  resource: resources.Packagedproductdefinition,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) ->
      Ok(any_delete(
        id,
        resources.RtPackagedproductdefinition,
        client,
        handle_response,
      ))
    None -> Error(ErrNoId)
  }
}

pub fn patient_create(
  resource: resources.Patient,
  client: FhirClient,
  handle_response: fn(Result(resources.Patient, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.patient_to_json(resource),
    resources.RtPatient,
    resources.patient_decoder(),
    client,
    handle_response,
  )
}

pub fn patient_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.Patient, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtPatient,
    resources.patient_decoder(),
    client,
    handle_response,
  )
}

pub fn patient_update(
  resource: resources.Patient,
  client: FhirClient,
  handle_response: fn(Result(resources.Patient, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.patient_to_json(resource),
    resources.RtPatient,
    resources.patient_decoder(),
    client,
    handle_response,
  )
}

pub fn patient_delete(
  resource: resources.Patient,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) -> Ok(any_delete(id, resources.RtPatient, client, handle_response))
    None -> Error(ErrNoId)
  }
}

pub fn paymentnotice_create(
  resource: resources.Paymentnotice,
  client: FhirClient,
  handle_response: fn(Result(resources.Paymentnotice, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.paymentnotice_to_json(resource),
    resources.RtPaymentnotice,
    resources.paymentnotice_decoder(),
    client,
    handle_response,
  )
}

pub fn paymentnotice_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.Paymentnotice, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtPaymentnotice,
    resources.paymentnotice_decoder(),
    client,
    handle_response,
  )
}

pub fn paymentnotice_update(
  resource: resources.Paymentnotice,
  client: FhirClient,
  handle_response: fn(Result(resources.Paymentnotice, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.paymentnotice_to_json(resource),
    resources.RtPaymentnotice,
    resources.paymentnotice_decoder(),
    client,
    handle_response,
  )
}

pub fn paymentnotice_delete(
  resource: resources.Paymentnotice,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) ->
      Ok(any_delete(id, resources.RtPaymentnotice, client, handle_response))
    None -> Error(ErrNoId)
  }
}

pub fn paymentreconciliation_create(
  resource: resources.Paymentreconciliation,
  client: FhirClient,
  handle_response: fn(Result(resources.Paymentreconciliation, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.paymentreconciliation_to_json(resource),
    resources.RtPaymentreconciliation,
    resources.paymentreconciliation_decoder(),
    client,
    handle_response,
  )
}

pub fn paymentreconciliation_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.Paymentreconciliation, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtPaymentreconciliation,
    resources.paymentreconciliation_decoder(),
    client,
    handle_response,
  )
}

pub fn paymentreconciliation_update(
  resource: resources.Paymentreconciliation,
  client: FhirClient,
  handle_response: fn(Result(resources.Paymentreconciliation, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.paymentreconciliation_to_json(resource),
    resources.RtPaymentreconciliation,
    resources.paymentreconciliation_decoder(),
    client,
    handle_response,
  )
}

pub fn paymentreconciliation_delete(
  resource: resources.Paymentreconciliation,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) ->
      Ok(any_delete(
        id,
        resources.RtPaymentreconciliation,
        client,
        handle_response,
      ))
    None -> Error(ErrNoId)
  }
}

pub fn permission_create(
  resource: resources.Permission,
  client: FhirClient,
  handle_response: fn(Result(resources.Permission, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.permission_to_json(resource),
    resources.RtPermission,
    resources.permission_decoder(),
    client,
    handle_response,
  )
}

pub fn permission_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.Permission, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtPermission,
    resources.permission_decoder(),
    client,
    handle_response,
  )
}

pub fn permission_update(
  resource: resources.Permission,
  client: FhirClient,
  handle_response: fn(Result(resources.Permission, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.permission_to_json(resource),
    resources.RtPermission,
    resources.permission_decoder(),
    client,
    handle_response,
  )
}

pub fn permission_delete(
  resource: resources.Permission,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) ->
      Ok(any_delete(id, resources.RtPermission, client, handle_response))
    None -> Error(ErrNoId)
  }
}

pub fn person_create(
  resource: resources.Person,
  client: FhirClient,
  handle_response: fn(Result(resources.Person, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.person_to_json(resource),
    resources.RtPerson,
    resources.person_decoder(),
    client,
    handle_response,
  )
}

pub fn person_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.Person, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtPerson,
    resources.person_decoder(),
    client,
    handle_response,
  )
}

pub fn person_update(
  resource: resources.Person,
  client: FhirClient,
  handle_response: fn(Result(resources.Person, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.person_to_json(resource),
    resources.RtPerson,
    resources.person_decoder(),
    client,
    handle_response,
  )
}

pub fn person_delete(
  resource: resources.Person,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) -> Ok(any_delete(id, resources.RtPerson, client, handle_response))
    None -> Error(ErrNoId)
  }
}

pub fn plandefinition_create(
  resource: resources.Plandefinition,
  client: FhirClient,
  handle_response: fn(Result(resources.Plandefinition, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.plandefinition_to_json(resource),
    resources.RtPlandefinition,
    resources.plandefinition_decoder(),
    client,
    handle_response,
  )
}

pub fn plandefinition_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.Plandefinition, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtPlandefinition,
    resources.plandefinition_decoder(),
    client,
    handle_response,
  )
}

pub fn plandefinition_update(
  resource: resources.Plandefinition,
  client: FhirClient,
  handle_response: fn(Result(resources.Plandefinition, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.plandefinition_to_json(resource),
    resources.RtPlandefinition,
    resources.plandefinition_decoder(),
    client,
    handle_response,
  )
}

pub fn plandefinition_delete(
  resource: resources.Plandefinition,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) ->
      Ok(any_delete(id, resources.RtPlandefinition, client, handle_response))
    None -> Error(ErrNoId)
  }
}

pub fn practitioner_create(
  resource: resources.Practitioner,
  client: FhirClient,
  handle_response: fn(Result(resources.Practitioner, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.practitioner_to_json(resource),
    resources.RtPractitioner,
    resources.practitioner_decoder(),
    client,
    handle_response,
  )
}

pub fn practitioner_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.Practitioner, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtPractitioner,
    resources.practitioner_decoder(),
    client,
    handle_response,
  )
}

pub fn practitioner_update(
  resource: resources.Practitioner,
  client: FhirClient,
  handle_response: fn(Result(resources.Practitioner, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.practitioner_to_json(resource),
    resources.RtPractitioner,
    resources.practitioner_decoder(),
    client,
    handle_response,
  )
}

pub fn practitioner_delete(
  resource: resources.Practitioner,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) ->
      Ok(any_delete(id, resources.RtPractitioner, client, handle_response))
    None -> Error(ErrNoId)
  }
}

pub fn practitionerrole_create(
  resource: resources.Practitionerrole,
  client: FhirClient,
  handle_response: fn(Result(resources.Practitionerrole, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.practitionerrole_to_json(resource),
    resources.RtPractitionerrole,
    resources.practitionerrole_decoder(),
    client,
    handle_response,
  )
}

pub fn practitionerrole_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.Practitionerrole, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtPractitionerrole,
    resources.practitionerrole_decoder(),
    client,
    handle_response,
  )
}

pub fn practitionerrole_update(
  resource: resources.Practitionerrole,
  client: FhirClient,
  handle_response: fn(Result(resources.Practitionerrole, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.practitionerrole_to_json(resource),
    resources.RtPractitionerrole,
    resources.practitionerrole_decoder(),
    client,
    handle_response,
  )
}

pub fn practitionerrole_delete(
  resource: resources.Practitionerrole,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) ->
      Ok(any_delete(id, resources.RtPractitionerrole, client, handle_response))
    None -> Error(ErrNoId)
  }
}

pub fn procedure_create(
  resource: resources.Procedure,
  client: FhirClient,
  handle_response: fn(Result(resources.Procedure, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.procedure_to_json(resource),
    resources.RtProcedure,
    resources.procedure_decoder(),
    client,
    handle_response,
  )
}

pub fn procedure_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.Procedure, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtProcedure,
    resources.procedure_decoder(),
    client,
    handle_response,
  )
}

pub fn procedure_update(
  resource: resources.Procedure,
  client: FhirClient,
  handle_response: fn(Result(resources.Procedure, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.procedure_to_json(resource),
    resources.RtProcedure,
    resources.procedure_decoder(),
    client,
    handle_response,
  )
}

pub fn procedure_delete(
  resource: resources.Procedure,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) ->
      Ok(any_delete(id, resources.RtProcedure, client, handle_response))
    None -> Error(ErrNoId)
  }
}

pub fn provenance_create(
  resource: resources.Provenance,
  client: FhirClient,
  handle_response: fn(Result(resources.Provenance, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.provenance_to_json(resource),
    resources.RtProvenance,
    resources.provenance_decoder(),
    client,
    handle_response,
  )
}

pub fn provenance_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.Provenance, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtProvenance,
    resources.provenance_decoder(),
    client,
    handle_response,
  )
}

pub fn provenance_update(
  resource: resources.Provenance,
  client: FhirClient,
  handle_response: fn(Result(resources.Provenance, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.provenance_to_json(resource),
    resources.RtProvenance,
    resources.provenance_decoder(),
    client,
    handle_response,
  )
}

pub fn provenance_delete(
  resource: resources.Provenance,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) ->
      Ok(any_delete(id, resources.RtProvenance, client, handle_response))
    None -> Error(ErrNoId)
  }
}

pub fn questionnaire_create(
  resource: resources.Questionnaire,
  client: FhirClient,
  handle_response: fn(Result(resources.Questionnaire, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.questionnaire_to_json(resource),
    resources.RtQuestionnaire,
    resources.questionnaire_decoder(),
    client,
    handle_response,
  )
}

pub fn questionnaire_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.Questionnaire, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtQuestionnaire,
    resources.questionnaire_decoder(),
    client,
    handle_response,
  )
}

pub fn questionnaire_update(
  resource: resources.Questionnaire,
  client: FhirClient,
  handle_response: fn(Result(resources.Questionnaire, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.questionnaire_to_json(resource),
    resources.RtQuestionnaire,
    resources.questionnaire_decoder(),
    client,
    handle_response,
  )
}

pub fn questionnaire_delete(
  resource: resources.Questionnaire,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) ->
      Ok(any_delete(id, resources.RtQuestionnaire, client, handle_response))
    None -> Error(ErrNoId)
  }
}

pub fn questionnaireresponse_create(
  resource: resources.Questionnaireresponse,
  client: FhirClient,
  handle_response: fn(Result(resources.Questionnaireresponse, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.questionnaireresponse_to_json(resource),
    resources.RtQuestionnaireresponse,
    resources.questionnaireresponse_decoder(),
    client,
    handle_response,
  )
}

pub fn questionnaireresponse_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.Questionnaireresponse, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtQuestionnaireresponse,
    resources.questionnaireresponse_decoder(),
    client,
    handle_response,
  )
}

pub fn questionnaireresponse_update(
  resource: resources.Questionnaireresponse,
  client: FhirClient,
  handle_response: fn(Result(resources.Questionnaireresponse, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.questionnaireresponse_to_json(resource),
    resources.RtQuestionnaireresponse,
    resources.questionnaireresponse_decoder(),
    client,
    handle_response,
  )
}

pub fn questionnaireresponse_delete(
  resource: resources.Questionnaireresponse,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) ->
      Ok(any_delete(
        id,
        resources.RtQuestionnaireresponse,
        client,
        handle_response,
      ))
    None -> Error(ErrNoId)
  }
}

pub fn regulatedauthorization_create(
  resource: resources.Regulatedauthorization,
  client: FhirClient,
  handle_response: fn(Result(resources.Regulatedauthorization, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.regulatedauthorization_to_json(resource),
    resources.RtRegulatedauthorization,
    resources.regulatedauthorization_decoder(),
    client,
    handle_response,
  )
}

pub fn regulatedauthorization_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.Regulatedauthorization, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtRegulatedauthorization,
    resources.regulatedauthorization_decoder(),
    client,
    handle_response,
  )
}

pub fn regulatedauthorization_update(
  resource: resources.Regulatedauthorization,
  client: FhirClient,
  handle_response: fn(Result(resources.Regulatedauthorization, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.regulatedauthorization_to_json(resource),
    resources.RtRegulatedauthorization,
    resources.regulatedauthorization_decoder(),
    client,
    handle_response,
  )
}

pub fn regulatedauthorization_delete(
  resource: resources.Regulatedauthorization,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) ->
      Ok(any_delete(
        id,
        resources.RtRegulatedauthorization,
        client,
        handle_response,
      ))
    None -> Error(ErrNoId)
  }
}

pub fn relatedperson_create(
  resource: resources.Relatedperson,
  client: FhirClient,
  handle_response: fn(Result(resources.Relatedperson, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.relatedperson_to_json(resource),
    resources.RtRelatedperson,
    resources.relatedperson_decoder(),
    client,
    handle_response,
  )
}

pub fn relatedperson_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.Relatedperson, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtRelatedperson,
    resources.relatedperson_decoder(),
    client,
    handle_response,
  )
}

pub fn relatedperson_update(
  resource: resources.Relatedperson,
  client: FhirClient,
  handle_response: fn(Result(resources.Relatedperson, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.relatedperson_to_json(resource),
    resources.RtRelatedperson,
    resources.relatedperson_decoder(),
    client,
    handle_response,
  )
}

pub fn relatedperson_delete(
  resource: resources.Relatedperson,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) ->
      Ok(any_delete(id, resources.RtRelatedperson, client, handle_response))
    None -> Error(ErrNoId)
  }
}

pub fn requestorchestration_create(
  resource: resources.Requestorchestration,
  client: FhirClient,
  handle_response: fn(Result(resources.Requestorchestration, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.requestorchestration_to_json(resource),
    resources.RtRequestorchestration,
    resources.requestorchestration_decoder(),
    client,
    handle_response,
  )
}

pub fn requestorchestration_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.Requestorchestration, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtRequestorchestration,
    resources.requestorchestration_decoder(),
    client,
    handle_response,
  )
}

pub fn requestorchestration_update(
  resource: resources.Requestorchestration,
  client: FhirClient,
  handle_response: fn(Result(resources.Requestorchestration, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.requestorchestration_to_json(resource),
    resources.RtRequestorchestration,
    resources.requestorchestration_decoder(),
    client,
    handle_response,
  )
}

pub fn requestorchestration_delete(
  resource: resources.Requestorchestration,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) ->
      Ok(any_delete(
        id,
        resources.RtRequestorchestration,
        client,
        handle_response,
      ))
    None -> Error(ErrNoId)
  }
}

pub fn requirements_create(
  resource: resources.Requirements,
  client: FhirClient,
  handle_response: fn(Result(resources.Requirements, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.requirements_to_json(resource),
    resources.RtRequirements,
    resources.requirements_decoder(),
    client,
    handle_response,
  )
}

pub fn requirements_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.Requirements, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtRequirements,
    resources.requirements_decoder(),
    client,
    handle_response,
  )
}

pub fn requirements_update(
  resource: resources.Requirements,
  client: FhirClient,
  handle_response: fn(Result(resources.Requirements, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.requirements_to_json(resource),
    resources.RtRequirements,
    resources.requirements_decoder(),
    client,
    handle_response,
  )
}

pub fn requirements_delete(
  resource: resources.Requirements,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) ->
      Ok(any_delete(id, resources.RtRequirements, client, handle_response))
    None -> Error(ErrNoId)
  }
}

pub fn researchstudy_create(
  resource: resources.Researchstudy,
  client: FhirClient,
  handle_response: fn(Result(resources.Researchstudy, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.researchstudy_to_json(resource),
    resources.RtResearchstudy,
    resources.researchstudy_decoder(),
    client,
    handle_response,
  )
}

pub fn researchstudy_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.Researchstudy, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtResearchstudy,
    resources.researchstudy_decoder(),
    client,
    handle_response,
  )
}

pub fn researchstudy_update(
  resource: resources.Researchstudy,
  client: FhirClient,
  handle_response: fn(Result(resources.Researchstudy, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.researchstudy_to_json(resource),
    resources.RtResearchstudy,
    resources.researchstudy_decoder(),
    client,
    handle_response,
  )
}

pub fn researchstudy_delete(
  resource: resources.Researchstudy,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) ->
      Ok(any_delete(id, resources.RtResearchstudy, client, handle_response))
    None -> Error(ErrNoId)
  }
}

pub fn researchsubject_create(
  resource: resources.Researchsubject,
  client: FhirClient,
  handle_response: fn(Result(resources.Researchsubject, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.researchsubject_to_json(resource),
    resources.RtResearchsubject,
    resources.researchsubject_decoder(),
    client,
    handle_response,
  )
}

pub fn researchsubject_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.Researchsubject, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtResearchsubject,
    resources.researchsubject_decoder(),
    client,
    handle_response,
  )
}

pub fn researchsubject_update(
  resource: resources.Researchsubject,
  client: FhirClient,
  handle_response: fn(Result(resources.Researchsubject, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.researchsubject_to_json(resource),
    resources.RtResearchsubject,
    resources.researchsubject_decoder(),
    client,
    handle_response,
  )
}

pub fn researchsubject_delete(
  resource: resources.Researchsubject,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) ->
      Ok(any_delete(id, resources.RtResearchsubject, client, handle_response))
    None -> Error(ErrNoId)
  }
}

pub fn riskassessment_create(
  resource: resources.Riskassessment,
  client: FhirClient,
  handle_response: fn(Result(resources.Riskassessment, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.riskassessment_to_json(resource),
    resources.RtRiskassessment,
    resources.riskassessment_decoder(),
    client,
    handle_response,
  )
}

pub fn riskassessment_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.Riskassessment, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtRiskassessment,
    resources.riskassessment_decoder(),
    client,
    handle_response,
  )
}

pub fn riskassessment_update(
  resource: resources.Riskassessment,
  client: FhirClient,
  handle_response: fn(Result(resources.Riskassessment, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.riskassessment_to_json(resource),
    resources.RtRiskassessment,
    resources.riskassessment_decoder(),
    client,
    handle_response,
  )
}

pub fn riskassessment_delete(
  resource: resources.Riskassessment,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) ->
      Ok(any_delete(id, resources.RtRiskassessment, client, handle_response))
    None -> Error(ErrNoId)
  }
}

pub fn schedule_create(
  resource: resources.Schedule,
  client: FhirClient,
  handle_response: fn(Result(resources.Schedule, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.schedule_to_json(resource),
    resources.RtSchedule,
    resources.schedule_decoder(),
    client,
    handle_response,
  )
}

pub fn schedule_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.Schedule, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtSchedule,
    resources.schedule_decoder(),
    client,
    handle_response,
  )
}

pub fn schedule_update(
  resource: resources.Schedule,
  client: FhirClient,
  handle_response: fn(Result(resources.Schedule, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.schedule_to_json(resource),
    resources.RtSchedule,
    resources.schedule_decoder(),
    client,
    handle_response,
  )
}

pub fn schedule_delete(
  resource: resources.Schedule,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) ->
      Ok(any_delete(id, resources.RtSchedule, client, handle_response))
    None -> Error(ErrNoId)
  }
}

pub fn searchparameter_create(
  resource: resources.Searchparameter,
  client: FhirClient,
  handle_response: fn(Result(resources.Searchparameter, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.searchparameter_to_json(resource),
    resources.RtSearchparameter,
    resources.searchparameter_decoder(),
    client,
    handle_response,
  )
}

pub fn searchparameter_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.Searchparameter, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtSearchparameter,
    resources.searchparameter_decoder(),
    client,
    handle_response,
  )
}

pub fn searchparameter_update(
  resource: resources.Searchparameter,
  client: FhirClient,
  handle_response: fn(Result(resources.Searchparameter, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.searchparameter_to_json(resource),
    resources.RtSearchparameter,
    resources.searchparameter_decoder(),
    client,
    handle_response,
  )
}

pub fn searchparameter_delete(
  resource: resources.Searchparameter,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) ->
      Ok(any_delete(id, resources.RtSearchparameter, client, handle_response))
    None -> Error(ErrNoId)
  }
}

pub fn servicerequest_create(
  resource: resources.Servicerequest,
  client: FhirClient,
  handle_response: fn(Result(resources.Servicerequest, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.servicerequest_to_json(resource),
    resources.RtServicerequest,
    resources.servicerequest_decoder(),
    client,
    handle_response,
  )
}

pub fn servicerequest_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.Servicerequest, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtServicerequest,
    resources.servicerequest_decoder(),
    client,
    handle_response,
  )
}

pub fn servicerequest_update(
  resource: resources.Servicerequest,
  client: FhirClient,
  handle_response: fn(Result(resources.Servicerequest, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.servicerequest_to_json(resource),
    resources.RtServicerequest,
    resources.servicerequest_decoder(),
    client,
    handle_response,
  )
}

pub fn servicerequest_delete(
  resource: resources.Servicerequest,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) ->
      Ok(any_delete(id, resources.RtServicerequest, client, handle_response))
    None -> Error(ErrNoId)
  }
}

pub fn slot_create(
  resource: resources.Slot,
  client: FhirClient,
  handle_response: fn(Result(resources.Slot, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.slot_to_json(resource),
    resources.RtSlot,
    resources.slot_decoder(),
    client,
    handle_response,
  )
}

pub fn slot_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.Slot, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtSlot,
    resources.slot_decoder(),
    client,
    handle_response,
  )
}

pub fn slot_update(
  resource: resources.Slot,
  client: FhirClient,
  handle_response: fn(Result(resources.Slot, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.slot_to_json(resource),
    resources.RtSlot,
    resources.slot_decoder(),
    client,
    handle_response,
  )
}

pub fn slot_delete(
  resource: resources.Slot,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) -> Ok(any_delete(id, resources.RtSlot, client, handle_response))
    None -> Error(ErrNoId)
  }
}

pub fn specimen_create(
  resource: resources.Specimen,
  client: FhirClient,
  handle_response: fn(Result(resources.Specimen, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.specimen_to_json(resource),
    resources.RtSpecimen,
    resources.specimen_decoder(),
    client,
    handle_response,
  )
}

pub fn specimen_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.Specimen, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtSpecimen,
    resources.specimen_decoder(),
    client,
    handle_response,
  )
}

pub fn specimen_update(
  resource: resources.Specimen,
  client: FhirClient,
  handle_response: fn(Result(resources.Specimen, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.specimen_to_json(resource),
    resources.RtSpecimen,
    resources.specimen_decoder(),
    client,
    handle_response,
  )
}

pub fn specimen_delete(
  resource: resources.Specimen,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) ->
      Ok(any_delete(id, resources.RtSpecimen, client, handle_response))
    None -> Error(ErrNoId)
  }
}

pub fn specimendefinition_create(
  resource: resources.Specimendefinition,
  client: FhirClient,
  handle_response: fn(Result(resources.Specimendefinition, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.specimendefinition_to_json(resource),
    resources.RtSpecimendefinition,
    resources.specimendefinition_decoder(),
    client,
    handle_response,
  )
}

pub fn specimendefinition_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.Specimendefinition, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtSpecimendefinition,
    resources.specimendefinition_decoder(),
    client,
    handle_response,
  )
}

pub fn specimendefinition_update(
  resource: resources.Specimendefinition,
  client: FhirClient,
  handle_response: fn(Result(resources.Specimendefinition, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.specimendefinition_to_json(resource),
    resources.RtSpecimendefinition,
    resources.specimendefinition_decoder(),
    client,
    handle_response,
  )
}

pub fn specimendefinition_delete(
  resource: resources.Specimendefinition,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) ->
      Ok(any_delete(id, resources.RtSpecimendefinition, client, handle_response))
    None -> Error(ErrNoId)
  }
}

pub fn structuredefinition_create(
  resource: resources.Structuredefinition,
  client: FhirClient,
  handle_response: fn(Result(resources.Structuredefinition, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.structuredefinition_to_json(resource),
    resources.RtStructuredefinition,
    resources.structuredefinition_decoder(),
    client,
    handle_response,
  )
}

pub fn structuredefinition_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.Structuredefinition, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtStructuredefinition,
    resources.structuredefinition_decoder(),
    client,
    handle_response,
  )
}

pub fn structuredefinition_update(
  resource: resources.Structuredefinition,
  client: FhirClient,
  handle_response: fn(Result(resources.Structuredefinition, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.structuredefinition_to_json(resource),
    resources.RtStructuredefinition,
    resources.structuredefinition_decoder(),
    client,
    handle_response,
  )
}

pub fn structuredefinition_delete(
  resource: resources.Structuredefinition,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) ->
      Ok(any_delete(
        id,
        resources.RtStructuredefinition,
        client,
        handle_response,
      ))
    None -> Error(ErrNoId)
  }
}

pub fn structuremap_create(
  resource: resources.Structuremap,
  client: FhirClient,
  handle_response: fn(Result(resources.Structuremap, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.structuremap_to_json(resource),
    resources.RtStructuremap,
    resources.structuremap_decoder(),
    client,
    handle_response,
  )
}

pub fn structuremap_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.Structuremap, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtStructuremap,
    resources.structuremap_decoder(),
    client,
    handle_response,
  )
}

pub fn structuremap_update(
  resource: resources.Structuremap,
  client: FhirClient,
  handle_response: fn(Result(resources.Structuremap, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.structuremap_to_json(resource),
    resources.RtStructuremap,
    resources.structuremap_decoder(),
    client,
    handle_response,
  )
}

pub fn structuremap_delete(
  resource: resources.Structuremap,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) ->
      Ok(any_delete(id, resources.RtStructuremap, client, handle_response))
    None -> Error(ErrNoId)
  }
}

pub fn subscription_create(
  resource: resources.Subscription,
  client: FhirClient,
  handle_response: fn(Result(resources.Subscription, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.subscription_to_json(resource),
    resources.RtSubscription,
    resources.subscription_decoder(),
    client,
    handle_response,
  )
}

pub fn subscription_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.Subscription, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtSubscription,
    resources.subscription_decoder(),
    client,
    handle_response,
  )
}

pub fn subscription_update(
  resource: resources.Subscription,
  client: FhirClient,
  handle_response: fn(Result(resources.Subscription, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.subscription_to_json(resource),
    resources.RtSubscription,
    resources.subscription_decoder(),
    client,
    handle_response,
  )
}

pub fn subscription_delete(
  resource: resources.Subscription,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) ->
      Ok(any_delete(id, resources.RtSubscription, client, handle_response))
    None -> Error(ErrNoId)
  }
}

pub fn subscriptionstatus_create(
  resource: resources.Subscriptionstatus,
  client: FhirClient,
  handle_response: fn(Result(resources.Subscriptionstatus, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.subscriptionstatus_to_json(resource),
    resources.RtSubscriptionstatus,
    resources.subscriptionstatus_decoder(),
    client,
    handle_response,
  )
}

pub fn subscriptionstatus_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.Subscriptionstatus, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtSubscriptionstatus,
    resources.subscriptionstatus_decoder(),
    client,
    handle_response,
  )
}

pub fn subscriptionstatus_update(
  resource: resources.Subscriptionstatus,
  client: FhirClient,
  handle_response: fn(Result(resources.Subscriptionstatus, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.subscriptionstatus_to_json(resource),
    resources.RtSubscriptionstatus,
    resources.subscriptionstatus_decoder(),
    client,
    handle_response,
  )
}

pub fn subscriptionstatus_delete(
  resource: resources.Subscriptionstatus,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) ->
      Ok(any_delete(id, resources.RtSubscriptionstatus, client, handle_response))
    None -> Error(ErrNoId)
  }
}

pub fn subscriptiontopic_create(
  resource: resources.Subscriptiontopic,
  client: FhirClient,
  handle_response: fn(Result(resources.Subscriptiontopic, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.subscriptiontopic_to_json(resource),
    resources.RtSubscriptiontopic,
    resources.subscriptiontopic_decoder(),
    client,
    handle_response,
  )
}

pub fn subscriptiontopic_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.Subscriptiontopic, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtSubscriptiontopic,
    resources.subscriptiontopic_decoder(),
    client,
    handle_response,
  )
}

pub fn subscriptiontopic_update(
  resource: resources.Subscriptiontopic,
  client: FhirClient,
  handle_response: fn(Result(resources.Subscriptiontopic, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.subscriptiontopic_to_json(resource),
    resources.RtSubscriptiontopic,
    resources.subscriptiontopic_decoder(),
    client,
    handle_response,
  )
}

pub fn subscriptiontopic_delete(
  resource: resources.Subscriptiontopic,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) ->
      Ok(any_delete(id, resources.RtSubscriptiontopic, client, handle_response))
    None -> Error(ErrNoId)
  }
}

pub fn substance_create(
  resource: resources.Substance,
  client: FhirClient,
  handle_response: fn(Result(resources.Substance, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.substance_to_json(resource),
    resources.RtSubstance,
    resources.substance_decoder(),
    client,
    handle_response,
  )
}

pub fn substance_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.Substance, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtSubstance,
    resources.substance_decoder(),
    client,
    handle_response,
  )
}

pub fn substance_update(
  resource: resources.Substance,
  client: FhirClient,
  handle_response: fn(Result(resources.Substance, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.substance_to_json(resource),
    resources.RtSubstance,
    resources.substance_decoder(),
    client,
    handle_response,
  )
}

pub fn substance_delete(
  resource: resources.Substance,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) ->
      Ok(any_delete(id, resources.RtSubstance, client, handle_response))
    None -> Error(ErrNoId)
  }
}

pub fn substancedefinition_create(
  resource: resources.Substancedefinition,
  client: FhirClient,
  handle_response: fn(Result(resources.Substancedefinition, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.substancedefinition_to_json(resource),
    resources.RtSubstancedefinition,
    resources.substancedefinition_decoder(),
    client,
    handle_response,
  )
}

pub fn substancedefinition_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.Substancedefinition, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtSubstancedefinition,
    resources.substancedefinition_decoder(),
    client,
    handle_response,
  )
}

pub fn substancedefinition_update(
  resource: resources.Substancedefinition,
  client: FhirClient,
  handle_response: fn(Result(resources.Substancedefinition, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.substancedefinition_to_json(resource),
    resources.RtSubstancedefinition,
    resources.substancedefinition_decoder(),
    client,
    handle_response,
  )
}

pub fn substancedefinition_delete(
  resource: resources.Substancedefinition,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) ->
      Ok(any_delete(
        id,
        resources.RtSubstancedefinition,
        client,
        handle_response,
      ))
    None -> Error(ErrNoId)
  }
}

pub fn substancenucleicacid_create(
  resource: resources.Substancenucleicacid,
  client: FhirClient,
  handle_response: fn(Result(resources.Substancenucleicacid, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.substancenucleicacid_to_json(resource),
    resources.RtSubstancenucleicacid,
    resources.substancenucleicacid_decoder(),
    client,
    handle_response,
  )
}

pub fn substancenucleicacid_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.Substancenucleicacid, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtSubstancenucleicacid,
    resources.substancenucleicacid_decoder(),
    client,
    handle_response,
  )
}

pub fn substancenucleicacid_update(
  resource: resources.Substancenucleicacid,
  client: FhirClient,
  handle_response: fn(Result(resources.Substancenucleicacid, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.substancenucleicacid_to_json(resource),
    resources.RtSubstancenucleicacid,
    resources.substancenucleicacid_decoder(),
    client,
    handle_response,
  )
}

pub fn substancenucleicacid_delete(
  resource: resources.Substancenucleicacid,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) ->
      Ok(any_delete(
        id,
        resources.RtSubstancenucleicacid,
        client,
        handle_response,
      ))
    None -> Error(ErrNoId)
  }
}

pub fn substancepolymer_create(
  resource: resources.Substancepolymer,
  client: FhirClient,
  handle_response: fn(Result(resources.Substancepolymer, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.substancepolymer_to_json(resource),
    resources.RtSubstancepolymer,
    resources.substancepolymer_decoder(),
    client,
    handle_response,
  )
}

pub fn substancepolymer_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.Substancepolymer, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtSubstancepolymer,
    resources.substancepolymer_decoder(),
    client,
    handle_response,
  )
}

pub fn substancepolymer_update(
  resource: resources.Substancepolymer,
  client: FhirClient,
  handle_response: fn(Result(resources.Substancepolymer, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.substancepolymer_to_json(resource),
    resources.RtSubstancepolymer,
    resources.substancepolymer_decoder(),
    client,
    handle_response,
  )
}

pub fn substancepolymer_delete(
  resource: resources.Substancepolymer,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) ->
      Ok(any_delete(id, resources.RtSubstancepolymer, client, handle_response))
    None -> Error(ErrNoId)
  }
}

pub fn substanceprotein_create(
  resource: resources.Substanceprotein,
  client: FhirClient,
  handle_response: fn(Result(resources.Substanceprotein, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.substanceprotein_to_json(resource),
    resources.RtSubstanceprotein,
    resources.substanceprotein_decoder(),
    client,
    handle_response,
  )
}

pub fn substanceprotein_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.Substanceprotein, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtSubstanceprotein,
    resources.substanceprotein_decoder(),
    client,
    handle_response,
  )
}

pub fn substanceprotein_update(
  resource: resources.Substanceprotein,
  client: FhirClient,
  handle_response: fn(Result(resources.Substanceprotein, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.substanceprotein_to_json(resource),
    resources.RtSubstanceprotein,
    resources.substanceprotein_decoder(),
    client,
    handle_response,
  )
}

pub fn substanceprotein_delete(
  resource: resources.Substanceprotein,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) ->
      Ok(any_delete(id, resources.RtSubstanceprotein, client, handle_response))
    None -> Error(ErrNoId)
  }
}

pub fn substancereferenceinformation_create(
  resource: resources.Substancereferenceinformation,
  client: FhirClient,
  handle_response: fn(Result(resources.Substancereferenceinformation, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.substancereferenceinformation_to_json(resource),
    resources.RtSubstancereferenceinformation,
    resources.substancereferenceinformation_decoder(),
    client,
    handle_response,
  )
}

pub fn substancereferenceinformation_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.Substancereferenceinformation, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtSubstancereferenceinformation,
    resources.substancereferenceinformation_decoder(),
    client,
    handle_response,
  )
}

pub fn substancereferenceinformation_update(
  resource: resources.Substancereferenceinformation,
  client: FhirClient,
  handle_response: fn(Result(resources.Substancereferenceinformation, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.substancereferenceinformation_to_json(resource),
    resources.RtSubstancereferenceinformation,
    resources.substancereferenceinformation_decoder(),
    client,
    handle_response,
  )
}

pub fn substancereferenceinformation_delete(
  resource: resources.Substancereferenceinformation,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) ->
      Ok(any_delete(
        id,
        resources.RtSubstancereferenceinformation,
        client,
        handle_response,
      ))
    None -> Error(ErrNoId)
  }
}

pub fn substancesourcematerial_create(
  resource: resources.Substancesourcematerial,
  client: FhirClient,
  handle_response: fn(Result(resources.Substancesourcematerial, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.substancesourcematerial_to_json(resource),
    resources.RtSubstancesourcematerial,
    resources.substancesourcematerial_decoder(),
    client,
    handle_response,
  )
}

pub fn substancesourcematerial_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.Substancesourcematerial, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtSubstancesourcematerial,
    resources.substancesourcematerial_decoder(),
    client,
    handle_response,
  )
}

pub fn substancesourcematerial_update(
  resource: resources.Substancesourcematerial,
  client: FhirClient,
  handle_response: fn(Result(resources.Substancesourcematerial, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.substancesourcematerial_to_json(resource),
    resources.RtSubstancesourcematerial,
    resources.substancesourcematerial_decoder(),
    client,
    handle_response,
  )
}

pub fn substancesourcematerial_delete(
  resource: resources.Substancesourcematerial,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) ->
      Ok(any_delete(
        id,
        resources.RtSubstancesourcematerial,
        client,
        handle_response,
      ))
    None -> Error(ErrNoId)
  }
}

pub fn supplydelivery_create(
  resource: resources.Supplydelivery,
  client: FhirClient,
  handle_response: fn(Result(resources.Supplydelivery, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.supplydelivery_to_json(resource),
    resources.RtSupplydelivery,
    resources.supplydelivery_decoder(),
    client,
    handle_response,
  )
}

pub fn supplydelivery_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.Supplydelivery, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtSupplydelivery,
    resources.supplydelivery_decoder(),
    client,
    handle_response,
  )
}

pub fn supplydelivery_update(
  resource: resources.Supplydelivery,
  client: FhirClient,
  handle_response: fn(Result(resources.Supplydelivery, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.supplydelivery_to_json(resource),
    resources.RtSupplydelivery,
    resources.supplydelivery_decoder(),
    client,
    handle_response,
  )
}

pub fn supplydelivery_delete(
  resource: resources.Supplydelivery,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) ->
      Ok(any_delete(id, resources.RtSupplydelivery, client, handle_response))
    None -> Error(ErrNoId)
  }
}

pub fn supplyrequest_create(
  resource: resources.Supplyrequest,
  client: FhirClient,
  handle_response: fn(Result(resources.Supplyrequest, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.supplyrequest_to_json(resource),
    resources.RtSupplyrequest,
    resources.supplyrequest_decoder(),
    client,
    handle_response,
  )
}

pub fn supplyrequest_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.Supplyrequest, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtSupplyrequest,
    resources.supplyrequest_decoder(),
    client,
    handle_response,
  )
}

pub fn supplyrequest_update(
  resource: resources.Supplyrequest,
  client: FhirClient,
  handle_response: fn(Result(resources.Supplyrequest, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.supplyrequest_to_json(resource),
    resources.RtSupplyrequest,
    resources.supplyrequest_decoder(),
    client,
    handle_response,
  )
}

pub fn supplyrequest_delete(
  resource: resources.Supplyrequest,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) ->
      Ok(any_delete(id, resources.RtSupplyrequest, client, handle_response))
    None -> Error(ErrNoId)
  }
}

pub fn task_create(
  resource: resources.Task,
  client: FhirClient,
  handle_response: fn(Result(resources.Task, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.task_to_json(resource),
    resources.RtTask,
    resources.task_decoder(),
    client,
    handle_response,
  )
}

pub fn task_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.Task, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtTask,
    resources.task_decoder(),
    client,
    handle_response,
  )
}

pub fn task_update(
  resource: resources.Task,
  client: FhirClient,
  handle_response: fn(Result(resources.Task, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.task_to_json(resource),
    resources.RtTask,
    resources.task_decoder(),
    client,
    handle_response,
  )
}

pub fn task_delete(
  resource: resources.Task,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) -> Ok(any_delete(id, resources.RtTask, client, handle_response))
    None -> Error(ErrNoId)
  }
}

pub fn terminologycapabilities_create(
  resource: resources.Terminologycapabilities,
  client: FhirClient,
  handle_response: fn(Result(resources.Terminologycapabilities, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.terminologycapabilities_to_json(resource),
    resources.RtTerminologycapabilities,
    resources.terminologycapabilities_decoder(),
    client,
    handle_response,
  )
}

pub fn terminologycapabilities_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.Terminologycapabilities, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtTerminologycapabilities,
    resources.terminologycapabilities_decoder(),
    client,
    handle_response,
  )
}

pub fn terminologycapabilities_update(
  resource: resources.Terminologycapabilities,
  client: FhirClient,
  handle_response: fn(Result(resources.Terminologycapabilities, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.terminologycapabilities_to_json(resource),
    resources.RtTerminologycapabilities,
    resources.terminologycapabilities_decoder(),
    client,
    handle_response,
  )
}

pub fn terminologycapabilities_delete(
  resource: resources.Terminologycapabilities,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) ->
      Ok(any_delete(
        id,
        resources.RtTerminologycapabilities,
        client,
        handle_response,
      ))
    None -> Error(ErrNoId)
  }
}

pub fn testplan_create(
  resource: resources.Testplan,
  client: FhirClient,
  handle_response: fn(Result(resources.Testplan, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.testplan_to_json(resource),
    resources.RtTestplan,
    resources.testplan_decoder(),
    client,
    handle_response,
  )
}

pub fn testplan_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.Testplan, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtTestplan,
    resources.testplan_decoder(),
    client,
    handle_response,
  )
}

pub fn testplan_update(
  resource: resources.Testplan,
  client: FhirClient,
  handle_response: fn(Result(resources.Testplan, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.testplan_to_json(resource),
    resources.RtTestplan,
    resources.testplan_decoder(),
    client,
    handle_response,
  )
}

pub fn testplan_delete(
  resource: resources.Testplan,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) ->
      Ok(any_delete(id, resources.RtTestplan, client, handle_response))
    None -> Error(ErrNoId)
  }
}

pub fn testreport_create(
  resource: resources.Testreport,
  client: FhirClient,
  handle_response: fn(Result(resources.Testreport, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.testreport_to_json(resource),
    resources.RtTestreport,
    resources.testreport_decoder(),
    client,
    handle_response,
  )
}

pub fn testreport_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.Testreport, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtTestreport,
    resources.testreport_decoder(),
    client,
    handle_response,
  )
}

pub fn testreport_update(
  resource: resources.Testreport,
  client: FhirClient,
  handle_response: fn(Result(resources.Testreport, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.testreport_to_json(resource),
    resources.RtTestreport,
    resources.testreport_decoder(),
    client,
    handle_response,
  )
}

pub fn testreport_delete(
  resource: resources.Testreport,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) ->
      Ok(any_delete(id, resources.RtTestreport, client, handle_response))
    None -> Error(ErrNoId)
  }
}

pub fn testscript_create(
  resource: resources.Testscript,
  client: FhirClient,
  handle_response: fn(Result(resources.Testscript, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.testscript_to_json(resource),
    resources.RtTestscript,
    resources.testscript_decoder(),
    client,
    handle_response,
  )
}

pub fn testscript_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.Testscript, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtTestscript,
    resources.testscript_decoder(),
    client,
    handle_response,
  )
}

pub fn testscript_update(
  resource: resources.Testscript,
  client: FhirClient,
  handle_response: fn(Result(resources.Testscript, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.testscript_to_json(resource),
    resources.RtTestscript,
    resources.testscript_decoder(),
    client,
    handle_response,
  )
}

pub fn testscript_delete(
  resource: resources.Testscript,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) ->
      Ok(any_delete(id, resources.RtTestscript, client, handle_response))
    None -> Error(ErrNoId)
  }
}

pub fn transport_create(
  resource: resources.Transport,
  client: FhirClient,
  handle_response: fn(Result(resources.Transport, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.transport_to_json(resource),
    resources.RtTransport,
    resources.transport_decoder(),
    client,
    handle_response,
  )
}

pub fn transport_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.Transport, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtTransport,
    resources.transport_decoder(),
    client,
    handle_response,
  )
}

pub fn transport_update(
  resource: resources.Transport,
  client: FhirClient,
  handle_response: fn(Result(resources.Transport, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.transport_to_json(resource),
    resources.RtTransport,
    resources.transport_decoder(),
    client,
    handle_response,
  )
}

pub fn transport_delete(
  resource: resources.Transport,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) ->
      Ok(any_delete(id, resources.RtTransport, client, handle_response))
    None -> Error(ErrNoId)
  }
}

pub fn valueset_create(
  resource: resources.Valueset,
  client: FhirClient,
  handle_response: fn(Result(resources.Valueset, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.valueset_to_json(resource),
    resources.RtValueset,
    resources.valueset_decoder(),
    client,
    handle_response,
  )
}

pub fn valueset_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.Valueset, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtValueset,
    resources.valueset_decoder(),
    client,
    handle_response,
  )
}

pub fn valueset_update(
  resource: resources.Valueset,
  client: FhirClient,
  handle_response: fn(Result(resources.Valueset, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.valueset_to_json(resource),
    resources.RtValueset,
    resources.valueset_decoder(),
    client,
    handle_response,
  )
}

pub fn valueset_delete(
  resource: resources.Valueset,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) ->
      Ok(any_delete(id, resources.RtValueset, client, handle_response))
    None -> Error(ErrNoId)
  }
}

pub fn verificationresult_create(
  resource: resources.Verificationresult,
  client: FhirClient,
  handle_response: fn(Result(resources.Verificationresult, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.verificationresult_to_json(resource),
    resources.RtVerificationresult,
    resources.verificationresult_decoder(),
    client,
    handle_response,
  )
}

pub fn verificationresult_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.Verificationresult, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtVerificationresult,
    resources.verificationresult_decoder(),
    client,
    handle_response,
  )
}

pub fn verificationresult_update(
  resource: resources.Verificationresult,
  client: FhirClient,
  handle_response: fn(Result(resources.Verificationresult, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.verificationresult_to_json(resource),
    resources.RtVerificationresult,
    resources.verificationresult_decoder(),
    client,
    handle_response,
  )
}

pub fn verificationresult_delete(
  resource: resources.Verificationresult,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) ->
      Ok(any_delete(id, resources.RtVerificationresult, client, handle_response))
    None -> Error(ErrNoId)
  }
}

pub fn visionprescription_create(
  resource: resources.Visionprescription,
  client: FhirClient,
  handle_response: fn(Result(resources.Visionprescription, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.visionprescription_to_json(resource),
    resources.RtVisionprescription,
    resources.visionprescription_decoder(),
    client,
    handle_response,
  )
}

pub fn visionprescription_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.Visionprescription, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtVisionprescription,
    resources.visionprescription_decoder(),
    client,
    handle_response,
  )
}

pub fn visionprescription_update(
  resource: resources.Visionprescription,
  client: FhirClient,
  handle_response: fn(Result(resources.Visionprescription, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.visionprescription_to_json(resource),
    resources.RtVisionprescription,
    resources.visionprescription_decoder(),
    client,
    handle_response,
  )
}

pub fn visionprescription_delete(
  resource: resources.Visionprescription,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) ->
      Ok(any_delete(id, resources.RtVisionprescription, client, handle_response))
    None -> Error(ErrNoId)
  }
}

pub fn account_search_bundled(
  sp: search_params.Account,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([
    #("owner", sp.owner),
    #("identifier", sp.identifier),
    #("period", sp.period),
    #("patient", sp.patient),
    #("subject", sp.subject),
    #("name", sp.name),
    #("guarantor", sp.guarantor),
    #("type", sp.type_),
    #("relatedaccount", sp.relatedaccount),
    #("status", sp.status),
  ])
  |> search_any(resources.RtAccount, client, handle_response)
}

pub fn account_search(
  sp: search_params.Account,
  client: FhirClient,
  handle_response: fn(Result(List(resources.Account), Err)) -> msg,
) -> Effect(msg) {
  account_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) -> Ok({ bundle |> sansio.bundle_to_groupedresources }.account)
      Error(error) -> Error(error)
    })
  })
}

pub fn activitydefinition_search_bundled(
  sp: search_params.Activitydefinition,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([
    #("date", sp.date),
    #("identifier", sp.identifier),
    #("successor", sp.successor),
    #("context-type-value", sp.context_type_value),
    #("kind", sp.kind),
    #("jurisdiction", sp.jurisdiction),
    #("derived-from", sp.derived_from),
    #("description", sp.description),
    #("context-type", sp.context_type),
    #("predecessor", sp.predecessor),
    #("composed-of", sp.composed_of),
    #("title", sp.title),
    #("version", sp.version),
    #("url", sp.url),
    #("context-quantity", sp.context_quantity),
    #("depends-on", sp.depends_on),
    #("effective", sp.effective),
    #("context", sp.context),
    #("name", sp.name),
    #("publisher", sp.publisher),
    #("topic", sp.topic),
    #("context-type-quantity", sp.context_type_quantity),
    #("status", sp.status),
  ])
  |> search_any(resources.RtActivitydefinition, client, handle_response)
}

pub fn activitydefinition_search(
  sp: search_params.Activitydefinition,
  client: FhirClient,
  handle_response: fn(Result(List(resources.Activitydefinition), Err)) -> msg,
) -> Effect(msg) {
  activitydefinition_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) ->
        Ok({ bundle |> sansio.bundle_to_groupedresources }.activitydefinition)
      Error(error) -> Error(error)
    })
  })
}

pub fn actordefinition_search_bundled(
  sp: search_params.Actordefinition,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([
    #("date", sp.date),
    #("identifier", sp.identifier),
    #("context-type-value", sp.context_type_value),
    #("jurisdiction", sp.jurisdiction),
    #("description", sp.description),
    #("context-type", sp.context_type),
    #("title", sp.title),
    #("type", sp.type_),
    #("version", sp.version),
    #("url", sp.url),
    #("context-quantity", sp.context_quantity),
    #("context", sp.context),
    #("publisher", sp.publisher),
    #("context-type-quantity", sp.context_type_quantity),
    #("status", sp.status),
  ])
  |> search_any(resources.RtActordefinition, client, handle_response)
}

pub fn actordefinition_search(
  sp: search_params.Actordefinition,
  client: FhirClient,
  handle_response: fn(Result(List(resources.Actordefinition), Err)) -> msg,
) -> Effect(msg) {
  actordefinition_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) ->
        Ok({ bundle |> sansio.bundle_to_groupedresources }.actordefinition)
      Error(error) -> Error(error)
    })
  })
}

pub fn administrableproductdefinition_search_bundled(
  sp: search_params.Administrableproductdefinition,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([
    #("identifier", sp.identifier),
    #("manufactured-item", sp.manufactured_item),
    #("ingredient", sp.ingredient),
    #("route", sp.route),
    #("dose-form", sp.dose_form),
    #("device", sp.device),
    #("form-of", sp.form_of),
    #("target-species", sp.target_species),
    #("status", sp.status),
  ])
  |> search_any(
    resources.RtAdministrableproductdefinition,
    client,
    handle_response,
  )
}

pub fn administrableproductdefinition_search(
  sp: search_params.Administrableproductdefinition,
  client: FhirClient,
  handle_response: fn(
    Result(List(resources.Administrableproductdefinition), Err),
  ) ->
    msg,
) -> Effect(msg) {
  administrableproductdefinition_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) ->
        Ok(
          { bundle |> sansio.bundle_to_groupedresources }.administrableproductdefinition,
        )
      Error(error) -> Error(error)
    })
  })
}

pub fn adverseevent_search_bundled(
  sp: search_params.Adverseevent,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([
    #("date", sp.date),
    #("identifier", sp.identifier),
    #("recorder", sp.recorder),
    #("study", sp.study),
    #("code", sp.code),
    #("actuality", sp.actuality),
    #("subject", sp.subject),
    #("substance", sp.substance),
    #("patient", sp.patient),
    #("resultingeffect", sp.resultingeffect),
    #("seriousness", sp.seriousness),
    #("location", sp.location),
    #("category", sp.category),
    #("status", sp.status),
  ])
  |> search_any(resources.RtAdverseevent, client, handle_response)
}

pub fn adverseevent_search(
  sp: search_params.Adverseevent,
  client: FhirClient,
  handle_response: fn(Result(List(resources.Adverseevent), Err)) -> msg,
) -> Effect(msg) {
  adverseevent_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) ->
        Ok({ bundle |> sansio.bundle_to_groupedresources }.adverseevent)
      Error(error) -> Error(error)
    })
  })
}

pub fn allergyintolerance_search_bundled(
  sp: search_params.Allergyintolerance,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([
    #("date", sp.date),
    #("severity", sp.severity),
    #("identifier", sp.identifier),
    #("code", sp.code),
    #("verification-status", sp.verification_status),
    #("criticality", sp.criticality),
    #("manifestation-reference", sp.manifestation_reference),
    #("clinical-status", sp.clinical_status),
    #("type", sp.type_),
    #("participant", sp.participant),
    #("manifestation-code", sp.manifestation_code),
    #("route", sp.route),
    #("patient", sp.patient),
    #("category", sp.category),
    #("last-date", sp.last_date),
  ])
  |> search_any(resources.RtAllergyintolerance, client, handle_response)
}

pub fn allergyintolerance_search(
  sp: search_params.Allergyintolerance,
  client: FhirClient,
  handle_response: fn(Result(List(resources.Allergyintolerance), Err)) -> msg,
) -> Effect(msg) {
  allergyintolerance_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) ->
        Ok({ bundle |> sansio.bundle_to_groupedresources }.allergyintolerance)
      Error(error) -> Error(error)
    })
  })
}

pub fn appointment_search_bundled(
  sp: search_params.Appointment,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([
    #("date", sp.date),
    #("identifier", sp.identifier),
    #("specialty", sp.specialty),
    #("service-category", sp.service_category),
    #("practitioner", sp.practitioner),
    #("appointment-type", sp.appointment_type),
    #("part-status", sp.part_status),
    #("subject", sp.subject),
    #("service-type", sp.service_type),
    #("slot", sp.slot),
    #("reason-code", sp.reason_code),
    #("actor", sp.actor),
    #("based-on", sp.based_on),
    #("patient", sp.patient),
    #("reason-reference", sp.reason_reference),
    #("supporting-info", sp.supporting_info),
    #("requested-period", sp.requested_period),
    #("location", sp.location),
    #("group", sp.group),
    #("service-type-reference", sp.service_type_reference),
    #("status", sp.status),
  ])
  |> search_any(resources.RtAppointment, client, handle_response)
}

pub fn appointment_search(
  sp: search_params.Appointment,
  client: FhirClient,
  handle_response: fn(Result(List(resources.Appointment), Err)) -> msg,
) -> Effect(msg) {
  appointment_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) ->
        Ok({ bundle |> sansio.bundle_to_groupedresources }.appointment)
      Error(error) -> Error(error)
    })
  })
}

pub fn appointmentresponse_search_bundled(
  sp: search_params.Appointmentresponse,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([
    #("actor", sp.actor),
    #("identifier", sp.identifier),
    #("practitioner", sp.practitioner),
    #("part-status", sp.part_status),
    #("patient", sp.patient),
    #("appointment", sp.appointment),
    #("location", sp.location),
    #("group", sp.group),
  ])
  |> search_any(resources.RtAppointmentresponse, client, handle_response)
}

pub fn appointmentresponse_search(
  sp: search_params.Appointmentresponse,
  client: FhirClient,
  handle_response: fn(Result(List(resources.Appointmentresponse), Err)) -> msg,
) -> Effect(msg) {
  appointmentresponse_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) ->
        Ok({ bundle |> sansio.bundle_to_groupedresources }.appointmentresponse)
      Error(error) -> Error(error)
    })
  })
}

pub fn artifactassessment_search_bundled(
  sp: search_params.Artifactassessment,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([
    #("date", sp.date),
    #("identifier", sp.identifier),
  ])
  |> search_any(resources.RtArtifactassessment, client, handle_response)
}

pub fn artifactassessment_search(
  sp: search_params.Artifactassessment,
  client: FhirClient,
  handle_response: fn(Result(List(resources.Artifactassessment), Err)) -> msg,
) -> Effect(msg) {
  artifactassessment_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) ->
        Ok({ bundle |> sansio.bundle_to_groupedresources }.artifactassessment)
      Error(error) -> Error(error)
    })
  })
}

pub fn auditevent_search_bundled(
  sp: search_params.Auditevent,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([
    #("date", sp.date),
    #("agent", sp.agent),
    #("entity-role", sp.entity_role),
    #("code", sp.code),
    #("purpose", sp.purpose),
    #("encounter", sp.encounter),
    #("source", sp.source),
    #("based-on", sp.based_on),
    #("patient", sp.patient),
    #("action", sp.action),
    #("agent-role", sp.agent_role),
    #("category", sp.category),
    #("entity", sp.entity),
    #("outcome", sp.outcome),
    #("policy", sp.policy),
  ])
  |> search_any(resources.RtAuditevent, client, handle_response)
}

pub fn auditevent_search(
  sp: search_params.Auditevent,
  client: FhirClient,
  handle_response: fn(Result(List(resources.Auditevent), Err)) -> msg,
) -> Effect(msg) {
  auditevent_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) ->
        Ok({ bundle |> sansio.bundle_to_groupedresources }.auditevent)
      Error(error) -> Error(error)
    })
  })
}

pub fn basic_search_bundled(
  sp: search_params.Basic,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([
    #("identifier", sp.identifier),
    #("code", sp.code),
    #("author", sp.author),
    #("created", sp.created),
    #("patient", sp.patient),
    #("subject", sp.subject),
  ])
  |> search_any(resources.RtBasic, client, handle_response)
}

pub fn basic_search(
  sp: search_params.Basic,
  client: FhirClient,
  handle_response: fn(Result(List(resources.Basic), Err)) -> msg,
) -> Effect(msg) {
  basic_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) -> Ok({ bundle |> sansio.bundle_to_groupedresources }.basic)
      Error(error) -> Error(error)
    })
  })
}

pub fn binary_search_bundled(
  _sp: search_params.Binary,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([])
  |> search_any(resources.RtBinary, client, handle_response)
}

pub fn binary_search(
  sp: search_params.Binary,
  client: FhirClient,
  handle_response: fn(Result(List(resources.Binary), Err)) -> msg,
) -> Effect(msg) {
  binary_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) -> Ok({ bundle |> sansio.bundle_to_groupedresources }.binary)
      Error(error) -> Error(error)
    })
  })
}

pub fn biologicallyderivedproduct_search_bundled(
  sp: search_params.Biologicallyderivedproduct,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([
    #("identifier", sp.identifier),
    #("request", sp.request),
    #("code", sp.code),
    #("product-status", sp.product_status),
    #("serial-number", sp.serial_number),
    #("biological-source-event", sp.biological_source_event),
    #("product-category", sp.product_category),
    #("collector", sp.collector),
  ])
  |> search_any(resources.RtBiologicallyderivedproduct, client, handle_response)
}

pub fn biologicallyderivedproduct_search(
  sp: search_params.Biologicallyderivedproduct,
  client: FhirClient,
  handle_response: fn(Result(List(resources.Biologicallyderivedproduct), Err)) ->
    msg,
) -> Effect(msg) {
  biologicallyderivedproduct_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) ->
        Ok(
          { bundle |> sansio.bundle_to_groupedresources }.biologicallyderivedproduct,
        )
      Error(error) -> Error(error)
    })
  })
}

pub fn biologicallyderivedproductdispense_search_bundled(
  sp: search_params.Biologicallyderivedproductdispense,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([
    #("identifier", sp.identifier),
    #("product", sp.product),
    #("performer", sp.performer),
    #("patient", sp.patient),
    #("status", sp.status),
  ])
  |> search_any(
    resources.RtBiologicallyderivedproductdispense,
    client,
    handle_response,
  )
}

pub fn biologicallyderivedproductdispense_search(
  sp: search_params.Biologicallyderivedproductdispense,
  client: FhirClient,
  handle_response: fn(
    Result(List(resources.Biologicallyderivedproductdispense), Err),
  ) ->
    msg,
) -> Effect(msg) {
  biologicallyderivedproductdispense_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) ->
        Ok(
          { bundle |> sansio.bundle_to_groupedresources }.biologicallyderivedproductdispense,
        )
      Error(error) -> Error(error)
    })
  })
}

pub fn bodystructure_search_bundled(
  sp: search_params.Bodystructure,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([
    #("identifier", sp.identifier),
    #("included_structure", sp.included_structure),
    #("excluded_structure", sp.excluded_structure),
    #("morphology", sp.morphology),
    #("patient", sp.patient),
  ])
  |> search_any(resources.RtBodystructure, client, handle_response)
}

pub fn bodystructure_search(
  sp: search_params.Bodystructure,
  client: FhirClient,
  handle_response: fn(Result(List(resources.Bodystructure), Err)) -> msg,
) -> Effect(msg) {
  bodystructure_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) ->
        Ok({ bundle |> sansio.bundle_to_groupedresources }.bodystructure)
      Error(error) -> Error(error)
    })
  })
}

pub fn bundle_search_bundled(
  sp: search_params.Bundle,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([
    #("identifier", sp.identifier),
    #("composition", sp.composition),
    #("message", sp.message),
    #("type", sp.type_),
    #("timestamp", sp.timestamp),
  ])
  |> search_any(resources.RtBundle, client, handle_response)
}

pub fn bundle_search(
  sp: search_params.Bundle,
  client: FhirClient,
  handle_response: fn(Result(List(resources.Bundle), Err)) -> msg,
) -> Effect(msg) {
  bundle_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) -> Ok({ bundle |> sansio.bundle_to_groupedresources }.bundle)
      Error(error) -> Error(error)
    })
  })
}

pub fn capabilitystatement_search_bundled(
  sp: search_params.Capabilitystatement,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([
    #("date", sp.date),
    #("identifier", sp.identifier),
    #("resource-profile", sp.resource_profile),
    #("context-type-value", sp.context_type_value),
    #("software", sp.software),
    #("resource", sp.resource),
    #("jurisdiction", sp.jurisdiction),
    #("format", sp.format),
    #("description", sp.description),
    #("context-type", sp.context_type),
    #("fhirversion", sp.fhirversion),
    #("title", sp.title),
    #("version", sp.version),
    #("supported-profile", sp.supported_profile),
    #("url", sp.url),
    #("mode", sp.mode),
    #("context-quantity", sp.context_quantity),
    #("security-service", sp.security_service),
    #("context", sp.context),
    #("name", sp.name),
    #("publisher", sp.publisher),
    #("context-type-quantity", sp.context_type_quantity),
    #("guide", sp.guide),
    #("status", sp.status),
  ])
  |> search_any(resources.RtCapabilitystatement, client, handle_response)
}

pub fn capabilitystatement_search(
  sp: search_params.Capabilitystatement,
  client: FhirClient,
  handle_response: fn(Result(List(resources.Capabilitystatement), Err)) -> msg,
) -> Effect(msg) {
  capabilitystatement_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) ->
        Ok({ bundle |> sansio.bundle_to_groupedresources }.capabilitystatement)
      Error(error) -> Error(error)
    })
  })
}

pub fn careplan_search_bundled(
  sp: search_params.Careplan,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([
    #("care-team", sp.care_team),
    #("date", sp.date),
    #("identifier", sp.identifier),
    #("goal", sp.goal),
    #("custodian", sp.custodian),
    #("replaces", sp.replaces),
    #("subject", sp.subject),
    #("instantiates-canonical", sp.instantiates_canonical),
    #("part-of", sp.part_of),
    #("encounter", sp.encounter),
    #("intent", sp.intent),
    #("activity-reference", sp.activity_reference),
    #("condition", sp.condition),
    #("based-on", sp.based_on),
    #("patient", sp.patient),
    #("instantiates-uri", sp.instantiates_uri),
    #("category", sp.category),
    #("status", sp.status),
  ])
  |> search_any(resources.RtCareplan, client, handle_response)
}

pub fn careplan_search(
  sp: search_params.Careplan,
  client: FhirClient,
  handle_response: fn(Result(List(resources.Careplan), Err)) -> msg,
) -> Effect(msg) {
  careplan_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) -> Ok({ bundle |> sansio.bundle_to_groupedresources }.careplan)
      Error(error) -> Error(error)
    })
  })
}

pub fn careteam_search_bundled(
  sp: search_params.Careteam,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([
    #("date", sp.date),
    #("identifier", sp.identifier),
    #("patient", sp.patient),
    #("subject", sp.subject),
    #("name", sp.name),
    #("category", sp.category),
    #("participant", sp.participant),
    #("status", sp.status),
  ])
  |> search_any(resources.RtCareteam, client, handle_response)
}

pub fn careteam_search(
  sp: search_params.Careteam,
  client: FhirClient,
  handle_response: fn(Result(List(resources.Careteam), Err)) -> msg,
) -> Effect(msg) {
  careteam_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) -> Ok({ bundle |> sansio.bundle_to_groupedresources }.careteam)
      Error(error) -> Error(error)
    })
  })
}

pub fn chargeitem_search_bundled(
  sp: search_params.Chargeitem,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([
    #("identifier", sp.identifier),
    #("performing-organization", sp.performing_organization),
    #("code", sp.code),
    #("quantity", sp.quantity),
    #("subject", sp.subject),
    #("encounter", sp.encounter),
    #("occurrence", sp.occurrence),
    #("entered-date", sp.entered_date),
    #("performer-function", sp.performer_function),
    #("factor-override", sp.factor_override),
    #("patient", sp.patient),
    #("service", sp.service),
    #("price-override", sp.price_override),
    #("enterer", sp.enterer),
    #("performer-actor", sp.performer_actor),
    #("account", sp.account),
    #("requesting-organization", sp.requesting_organization),
    #("status", sp.status),
  ])
  |> search_any(resources.RtChargeitem, client, handle_response)
}

pub fn chargeitem_search(
  sp: search_params.Chargeitem,
  client: FhirClient,
  handle_response: fn(Result(List(resources.Chargeitem), Err)) -> msg,
) -> Effect(msg) {
  chargeitem_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) ->
        Ok({ bundle |> sansio.bundle_to_groupedresources }.chargeitem)
      Error(error) -> Error(error)
    })
  })
}

pub fn chargeitemdefinition_search_bundled(
  sp: search_params.Chargeitemdefinition,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([
    #("date", sp.date),
    #("identifier", sp.identifier),
    #("context-type-value", sp.context_type_value),
    #("jurisdiction", sp.jurisdiction),
    #("description", sp.description),
    #("context-type", sp.context_type),
    #("title", sp.title),
    #("version", sp.version),
    #("url", sp.url),
    #("context-quantity", sp.context_quantity),
    #("effective", sp.effective),
    #("context", sp.context),
    #("publisher", sp.publisher),
    #("context-type-quantity", sp.context_type_quantity),
    #("status", sp.status),
  ])
  |> search_any(resources.RtChargeitemdefinition, client, handle_response)
}

pub fn chargeitemdefinition_search(
  sp: search_params.Chargeitemdefinition,
  client: FhirClient,
  handle_response: fn(Result(List(resources.Chargeitemdefinition), Err)) -> msg,
) -> Effect(msg) {
  chargeitemdefinition_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) ->
        Ok({ bundle |> sansio.bundle_to_groupedresources }.chargeitemdefinition)
      Error(error) -> Error(error)
    })
  })
}

pub fn citation_search_bundled(
  sp: search_params.Citation,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([
    #("date", sp.date),
    #("identifier", sp.identifier),
    #("context-type-value", sp.context_type_value),
    #("jurisdiction", sp.jurisdiction),
    #("description", sp.description),
    #("classification-type", sp.classification_type),
    #("context-type", sp.context_type),
    #("title", sp.title),
    #("classification", sp.classification),
    #("version", sp.version),
    #("url", sp.url),
    #("context-quantity", sp.context_quantity),
    #("effective", sp.effective),
    #("context", sp.context),
    #("name", sp.name),
    #("classifier", sp.classifier),
    #("publisher", sp.publisher),
    #("context-type-quantity", sp.context_type_quantity),
    #("status", sp.status),
  ])
  |> search_any(resources.RtCitation, client, handle_response)
}

pub fn citation_search(
  sp: search_params.Citation,
  client: FhirClient,
  handle_response: fn(Result(List(resources.Citation), Err)) -> msg,
) -> Effect(msg) {
  citation_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) -> Ok({ bundle |> sansio.bundle_to_groupedresources }.citation)
      Error(error) -> Error(error)
    })
  })
}

pub fn claim_search_bundled(
  sp: search_params.Claim,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([
    #("care-team", sp.care_team),
    #("identifier", sp.identifier),
    #("created", sp.created),
    #("use", sp.use_),
    #("encounter", sp.encounter),
    #("priority", sp.priority),
    #("payee", sp.payee),
    #("provider", sp.provider),
    #("insurer", sp.insurer),
    #("patient", sp.patient),
    #("detail-udi", sp.detail_udi),
    #("enterer", sp.enterer),
    #("procedure-udi", sp.procedure_udi),
    #("subdetail-udi", sp.subdetail_udi),
    #("facility", sp.facility),
    #("item-udi", sp.item_udi),
    #("status", sp.status),
  ])
  |> search_any(resources.RtClaim, client, handle_response)
}

pub fn claim_search(
  sp: search_params.Claim,
  client: FhirClient,
  handle_response: fn(Result(List(resources.Claim), Err)) -> msg,
) -> Effect(msg) {
  claim_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) -> Ok({ bundle |> sansio.bundle_to_groupedresources }.claim)
      Error(error) -> Error(error)
    })
  })
}

pub fn claimresponse_search_bundled(
  sp: search_params.Claimresponse,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([
    #("identifier", sp.identifier),
    #("request", sp.request),
    #("disposition", sp.disposition),
    #("created", sp.created),
    #("insurer", sp.insurer),
    #("patient", sp.patient),
    #("use", sp.use_),
    #("payment-date", sp.payment_date),
    #("outcome", sp.outcome),
    #("requestor", sp.requestor),
    #("status", sp.status),
  ])
  |> search_any(resources.RtClaimresponse, client, handle_response)
}

pub fn claimresponse_search(
  sp: search_params.Claimresponse,
  client: FhirClient,
  handle_response: fn(Result(List(resources.Claimresponse), Err)) -> msg,
) -> Effect(msg) {
  claimresponse_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) ->
        Ok({ bundle |> sansio.bundle_to_groupedresources }.claimresponse)
      Error(error) -> Error(error)
    })
  })
}

pub fn clinicalimpression_search_bundled(
  sp: search_params.Clinicalimpression,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([
    #("date", sp.date),
    #("identifier", sp.identifier),
    #("performer", sp.performer),
    #("problem", sp.problem),
    #("previous", sp.previous),
    #("finding-code", sp.finding_code),
    #("patient", sp.patient),
    #("subject", sp.subject),
    #("supporting-info", sp.supporting_info),
    #("encounter", sp.encounter),
    #("finding-ref", sp.finding_ref),
    #("status", sp.status),
  ])
  |> search_any(resources.RtClinicalimpression, client, handle_response)
}

pub fn clinicalimpression_search(
  sp: search_params.Clinicalimpression,
  client: FhirClient,
  handle_response: fn(Result(List(resources.Clinicalimpression), Err)) -> msg,
) -> Effect(msg) {
  clinicalimpression_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) ->
        Ok({ bundle |> sansio.bundle_to_groupedresources }.clinicalimpression)
      Error(error) -> Error(error)
    })
  })
}

pub fn clinicalusedefinition_search_bundled(
  sp: search_params.Clinicalusedefinition,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([
    #("contraindication-reference", sp.contraindication_reference),
    #("identifier", sp.identifier),
    #("indication-reference", sp.indication_reference),
    #("product", sp.product),
    #("subject", sp.subject),
    #("effect", sp.effect),
    #("interaction", sp.interaction),
    #("indication", sp.indication),
    #("type", sp.type_),
    #("contraindication", sp.contraindication),
    #("effect-reference", sp.effect_reference),
    #("status", sp.status),
  ])
  |> search_any(resources.RtClinicalusedefinition, client, handle_response)
}

pub fn clinicalusedefinition_search(
  sp: search_params.Clinicalusedefinition,
  client: FhirClient,
  handle_response: fn(Result(List(resources.Clinicalusedefinition), Err)) -> msg,
) -> Effect(msg) {
  clinicalusedefinition_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) ->
        Ok(
          { bundle |> sansio.bundle_to_groupedresources }.clinicalusedefinition,
        )
      Error(error) -> Error(error)
    })
  })
}

pub fn codesystem_search_bundled(
  sp: search_params.Codesystem,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([
    #("date", sp.date),
    #("identifier", sp.identifier),
    #("code", sp.code),
    #("context-type-value", sp.context_type_value),
    #("content-mode", sp.content_mode),
    #("jurisdiction", sp.jurisdiction),
    #("description", sp.description),
    #("derived-from", sp.derived_from),
    #("context-type", sp.context_type),
    #("language", sp.language),
    #("predecessor", sp.predecessor),
    #("title", sp.title),
    #("version", sp.version),
    #("url", sp.url),
    #("context-quantity", sp.context_quantity),
    #("supplements", sp.supplements),
    #("effective", sp.effective),
    #("system", sp.system),
    #("context", sp.context),
    #("name", sp.name),
    #("publisher", sp.publisher),
    #("topic", sp.topic),
    #("context-type-quantity", sp.context_type_quantity),
    #("status", sp.status),
  ])
  |> search_any(resources.RtCodesystem, client, handle_response)
}

pub fn codesystem_search(
  sp: search_params.Codesystem,
  client: FhirClient,
  handle_response: fn(Result(List(resources.Codesystem), Err)) -> msg,
) -> Effect(msg) {
  codesystem_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) ->
        Ok({ bundle |> sansio.bundle_to_groupedresources }.codesystem)
      Error(error) -> Error(error)
    })
  })
}

pub fn communication_search_bundled(
  sp: search_params.Communication,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([
    #("identifier", sp.identifier),
    #("subject", sp.subject),
    #("instantiates-canonical", sp.instantiates_canonical),
    #("part-of", sp.part_of),
    #("received", sp.received),
    #("encounter", sp.encounter),
    #("medium", sp.medium),
    #("sent", sp.sent),
    #("based-on", sp.based_on),
    #("sender", sp.sender),
    #("patient", sp.patient),
    #("recipient", sp.recipient),
    #("topic", sp.topic),
    #("instantiates-uri", sp.instantiates_uri),
    #("category", sp.category),
    #("status", sp.status),
  ])
  |> search_any(resources.RtCommunication, client, handle_response)
}

pub fn communication_search(
  sp: search_params.Communication,
  client: FhirClient,
  handle_response: fn(Result(List(resources.Communication), Err)) -> msg,
) -> Effect(msg) {
  communication_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) ->
        Ok({ bundle |> sansio.bundle_to_groupedresources }.communication)
      Error(error) -> Error(error)
    })
  })
}

pub fn communicationrequest_search_bundled(
  sp: search_params.Communicationrequest,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([
    #("authored", sp.authored),
    #("requester", sp.requester),
    #("identifier", sp.identifier),
    #("replaces", sp.replaces),
    #("subject", sp.subject),
    #("encounter", sp.encounter),
    #("medium", sp.medium),
    #("occurrence", sp.occurrence),
    #("priority", sp.priority),
    #("group-identifier", sp.group_identifier),
    #("based-on", sp.based_on),
    #("patient", sp.patient),
    #("recipient", sp.recipient),
    #("information-provider", sp.information_provider),
    #("category", sp.category),
    #("status", sp.status),
  ])
  |> search_any(resources.RtCommunicationrequest, client, handle_response)
}

pub fn communicationrequest_search(
  sp: search_params.Communicationrequest,
  client: FhirClient,
  handle_response: fn(Result(List(resources.Communicationrequest), Err)) -> msg,
) -> Effect(msg) {
  communicationrequest_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) ->
        Ok({ bundle |> sansio.bundle_to_groupedresources }.communicationrequest)
      Error(error) -> Error(error)
    })
  })
}

pub fn compartmentdefinition_search_bundled(
  sp: search_params.Compartmentdefinition,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([
    #("date", sp.date),
    #("code", sp.code),
    #("context-type-value", sp.context_type_value),
    #("resource", sp.resource),
    #("description", sp.description),
    #("context-type", sp.context_type),
    #("version", sp.version),
    #("url", sp.url),
    #("context-quantity", sp.context_quantity),
    #("context", sp.context),
    #("name", sp.name),
    #("publisher", sp.publisher),
    #("context-type-quantity", sp.context_type_quantity),
    #("status", sp.status),
  ])
  |> search_any(resources.RtCompartmentdefinition, client, handle_response)
}

pub fn compartmentdefinition_search(
  sp: search_params.Compartmentdefinition,
  client: FhirClient,
  handle_response: fn(Result(List(resources.Compartmentdefinition), Err)) -> msg,
) -> Effect(msg) {
  compartmentdefinition_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) ->
        Ok(
          { bundle |> sansio.bundle_to_groupedresources }.compartmentdefinition,
        )
      Error(error) -> Error(error)
    })
  })
}

pub fn composition_search_bundled(
  sp: search_params.Composition,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([
    #("date", sp.date),
    #("identifier", sp.identifier),
    #("period", sp.period),
    #("event-code", sp.event_code),
    #("author", sp.author),
    #("subject", sp.subject),
    #("section", sp.section),
    #("encounter", sp.encounter),
    #("title", sp.title),
    #("type", sp.type_),
    #("version", sp.version),
    #("attester", sp.attester),
    #("url", sp.url),
    #("event-reference", sp.event_reference),
    #("section-text", sp.section_text),
    #("entry", sp.entry),
    #("related", sp.related),
    #("patient", sp.patient),
    #("category", sp.category),
    #("section-code-text", sp.section_code_text),
    #("status", sp.status),
  ])
  |> search_any(resources.RtComposition, client, handle_response)
}

pub fn composition_search(
  sp: search_params.Composition,
  client: FhirClient,
  handle_response: fn(Result(List(resources.Composition), Err)) -> msg,
) -> Effect(msg) {
  composition_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) ->
        Ok({ bundle |> sansio.bundle_to_groupedresources }.composition)
      Error(error) -> Error(error)
    })
  })
}

pub fn conceptmap_search_bundled(
  sp: search_params.Conceptmap,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([
    #("date", sp.date),
    #("target-scope", sp.target_scope),
    #("context-type-value", sp.context_type_value),
    #("jurisdiction", sp.jurisdiction),
    #("description", sp.description),
    #("target-group-system", sp.target_group_system),
    #("derived-from", sp.derived_from),
    #("context-type", sp.context_type),
    #("predecessor", sp.predecessor),
    #("title", sp.title),
    #("context-quantity", sp.context_quantity),
    #("effective", sp.effective),
    #("source-scope", sp.source_scope),
    #("context", sp.context),
    #("context-type-quantity", sp.context_type_quantity),
    #("target-code", sp.target_code),
    #("identifier", sp.identifier),
    #("source-scope-uri", sp.source_scope_uri),
    #("source-group-system", sp.source_group_system),
    #("mapping-property", sp.mapping_property),
    #("other-map", sp.other_map),
    #("version", sp.version),
    #("url", sp.url),
    #("source-code", sp.source_code),
    #("target-scope-uri", sp.target_scope_uri),
    #("name", sp.name),
    #("publisher", sp.publisher),
    #("topic", sp.topic),
    #("status", sp.status),
  ])
  |> search_any(resources.RtConceptmap, client, handle_response)
}

pub fn conceptmap_search(
  sp: search_params.Conceptmap,
  client: FhirClient,
  handle_response: fn(Result(List(resources.Conceptmap), Err)) -> msg,
) -> Effect(msg) {
  conceptmap_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) ->
        Ok({ bundle |> sansio.bundle_to_groupedresources }.conceptmap)
      Error(error) -> Error(error)
    })
  })
}

pub fn condition_search_bundled(
  sp: search_params.Condition,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([
    #("evidence-detail", sp.evidence_detail),
    #("severity", sp.severity),
    #("identifier", sp.identifier),
    #("onset-info", sp.onset_info),
    #("recorded-date", sp.recorded_date),
    #("code", sp.code),
    #("evidence", sp.evidence),
    #("participant-function", sp.participant_function),
    #("subject", sp.subject),
    #("participant-actor", sp.participant_actor),
    #("verification-status", sp.verification_status),
    #("clinical-status", sp.clinical_status),
    #("encounter", sp.encounter),
    #("onset-date", sp.onset_date),
    #("abatement-date", sp.abatement_date),
    #("stage", sp.stage),
    #("abatement-string", sp.abatement_string),
    #("patient", sp.patient),
    #("abatement-age", sp.abatement_age),
    #("onset-age", sp.onset_age),
    #("body-site", sp.body_site),
    #("category", sp.category),
  ])
  |> search_any(resources.RtCondition, client, handle_response)
}

pub fn condition_search(
  sp: search_params.Condition,
  client: FhirClient,
  handle_response: fn(Result(List(resources.Condition), Err)) -> msg,
) -> Effect(msg) {
  condition_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) ->
        Ok({ bundle |> sansio.bundle_to_groupedresources }.condition)
      Error(error) -> Error(error)
    })
  })
}

pub fn conditiondefinition_search_bundled(
  sp: search_params.Conditiondefinition,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([
    #("date", sp.date),
    #("identifier", sp.identifier),
    #("context-type-value", sp.context_type_value),
    #("jurisdiction", sp.jurisdiction),
    #("description", sp.description),
    #("context-type", sp.context_type),
    #("title", sp.title),
    #("version", sp.version),
    #("url", sp.url),
    #("context-quantity", sp.context_quantity),
    #("context", sp.context),
    #("name", sp.name),
    #("publisher", sp.publisher),
    #("context-type-quantity", sp.context_type_quantity),
    #("status", sp.status),
  ])
  |> search_any(resources.RtConditiondefinition, client, handle_response)
}

pub fn conditiondefinition_search(
  sp: search_params.Conditiondefinition,
  client: FhirClient,
  handle_response: fn(Result(List(resources.Conditiondefinition), Err)) -> msg,
) -> Effect(msg) {
  conditiondefinition_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) ->
        Ok({ bundle |> sansio.bundle_to_groupedresources }.conditiondefinition)
      Error(error) -> Error(error)
    })
  })
}

pub fn consent_search_bundled(
  sp: search_params.Consent,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([
    #("date", sp.date),
    #("identifier", sp.identifier),
    #("controller", sp.controller),
    #("period", sp.period),
    #("data", sp.data),
    #("manager", sp.manager),
    #("purpose", sp.purpose),
    #("subject", sp.subject),
    #("verified-date", sp.verified_date),
    #("grantee", sp.grantee),
    #("source-reference", sp.source_reference),
    #("verified", sp.verified),
    #("actor", sp.actor),
    #("security-label", sp.security_label),
    #("patient", sp.patient),
    #("action", sp.action),
    #("category", sp.category),
    #("status", sp.status),
  ])
  |> search_any(resources.RtConsent, client, handle_response)
}

pub fn consent_search(
  sp: search_params.Consent,
  client: FhirClient,
  handle_response: fn(Result(List(resources.Consent), Err)) -> msg,
) -> Effect(msg) {
  consent_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) -> Ok({ bundle |> sansio.bundle_to_groupedresources }.consent)
      Error(error) -> Error(error)
    })
  })
}

pub fn contract_search_bundled(
  sp: search_params.Contract,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([
    #("identifier", sp.identifier),
    #("instantiates", sp.instantiates),
    #("patient", sp.patient),
    #("subject", sp.subject),
    #("authority", sp.authority),
    #("domain", sp.domain),
    #("issued", sp.issued),
    #("url", sp.url),
    #("signer", sp.signer),
    #("status", sp.status),
  ])
  |> search_any(resources.RtContract, client, handle_response)
}

pub fn contract_search(
  sp: search_params.Contract,
  client: FhirClient,
  handle_response: fn(Result(List(resources.Contract), Err)) -> msg,
) -> Effect(msg) {
  contract_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) -> Ok({ bundle |> sansio.bundle_to_groupedresources }.contract)
      Error(error) -> Error(error)
    })
  })
}

pub fn coverage_search_bundled(
  sp: search_params.Coverage,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([
    #("identifier", sp.identifier),
    #("subscriber", sp.subscriber),
    #("subscriberid", sp.subscriberid),
    #("type", sp.type_),
    #("beneficiary", sp.beneficiary),
    #("patient", sp.patient),
    #("insurer", sp.insurer),
    #("class-value", sp.class_value),
    #("paymentby-party", sp.paymentby_party),
    #("class-type", sp.class_type),
    #("dependent", sp.dependent),
    #("policy-holder", sp.policy_holder),
    #("status", sp.status),
  ])
  |> search_any(resources.RtCoverage, client, handle_response)
}

pub fn coverage_search(
  sp: search_params.Coverage,
  client: FhirClient,
  handle_response: fn(Result(List(resources.Coverage), Err)) -> msg,
) -> Effect(msg) {
  coverage_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) -> Ok({ bundle |> sansio.bundle_to_groupedresources }.coverage)
      Error(error) -> Error(error)
    })
  })
}

pub fn coverageeligibilityrequest_search_bundled(
  sp: search_params.Coverageeligibilityrequest,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([
    #("identifier", sp.identifier),
    #("provider", sp.provider),
    #("created", sp.created),
    #("patient", sp.patient),
    #("enterer", sp.enterer),
    #("facility", sp.facility),
    #("status", sp.status),
  ])
  |> search_any(resources.RtCoverageeligibilityrequest, client, handle_response)
}

pub fn coverageeligibilityrequest_search(
  sp: search_params.Coverageeligibilityrequest,
  client: FhirClient,
  handle_response: fn(Result(List(resources.Coverageeligibilityrequest), Err)) ->
    msg,
) -> Effect(msg) {
  coverageeligibilityrequest_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) ->
        Ok(
          { bundle |> sansio.bundle_to_groupedresources }.coverageeligibilityrequest,
        )
      Error(error) -> Error(error)
    })
  })
}

pub fn coverageeligibilityresponse_search_bundled(
  sp: search_params.Coverageeligibilityresponse,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([
    #("identifier", sp.identifier),
    #("request", sp.request),
    #("disposition", sp.disposition),
    #("created", sp.created),
    #("insurer", sp.insurer),
    #("patient", sp.patient),
    #("outcome", sp.outcome),
    #("requestor", sp.requestor),
    #("status", sp.status),
  ])
  |> search_any(
    resources.RtCoverageeligibilityresponse,
    client,
    handle_response,
  )
}

pub fn coverageeligibilityresponse_search(
  sp: search_params.Coverageeligibilityresponse,
  client: FhirClient,
  handle_response: fn(Result(List(resources.Coverageeligibilityresponse), Err)) ->
    msg,
) -> Effect(msg) {
  coverageeligibilityresponse_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) ->
        Ok(
          { bundle |> sansio.bundle_to_groupedresources }.coverageeligibilityresponse,
        )
      Error(error) -> Error(error)
    })
  })
}

pub fn detectedissue_search_bundled(
  sp: search_params.Detectedissue,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([
    #("identifier", sp.identifier),
    #("code", sp.code),
    #("identified", sp.identified),
    #("author", sp.author),
    #("subject", sp.subject),
    #("patient", sp.patient),
    #("implicated", sp.implicated),
    #("category", sp.category),
    #("status", sp.status),
  ])
  |> search_any(resources.RtDetectedissue, client, handle_response)
}

pub fn detectedissue_search(
  sp: search_params.Detectedissue,
  client: FhirClient,
  handle_response: fn(Result(List(resources.Detectedissue), Err)) -> msg,
) -> Effect(msg) {
  detectedissue_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) ->
        Ok({ bundle |> sansio.bundle_to_groupedresources }.detectedissue)
      Error(error) -> Error(error)
    })
  })
}

pub fn device_search_bundled(
  sp: search_params.Device,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([
    #("udi-di", sp.udi_di),
    #("identifier", sp.identifier),
    #("parent", sp.parent),
    #("manufacture-date", sp.manufacture_date),
    #("udi-carrier", sp.udi_carrier),
    #("code", sp.code),
    #("device-name", sp.device_name),
    #("lot-number", sp.lot_number),
    #("serial-number", sp.serial_number),
    #("specification", sp.specification),
    #("type", sp.type_),
    #("version", sp.version),
    #("url", sp.url),
    #("manufacturer", sp.manufacturer),
    #("code-value-concept", sp.code_value_concept),
    #("organization", sp.organization),
    #("biological-source-event", sp.biological_source_event),
    #("definition", sp.definition),
    #("location", sp.location),
    #("model", sp.model),
    #("expiration-date", sp.expiration_date),
    #("specification-version", sp.specification_version),
    #("status", sp.status),
  ])
  |> search_any(resources.RtDevice, client, handle_response)
}

pub fn device_search(
  sp: search_params.Device,
  client: FhirClient,
  handle_response: fn(Result(List(resources.Device), Err)) -> msg,
) -> Effect(msg) {
  device_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) -> Ok({ bundle |> sansio.bundle_to_groupedresources }.device)
      Error(error) -> Error(error)
    })
  })
}

pub fn deviceassociation_search_bundled(
  sp: search_params.Deviceassociation,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([
    #("identifier", sp.identifier),
    #("subject", sp.subject),
    #("patient", sp.patient),
    #("device", sp.device),
    #("operator", sp.operator),
    #("status", sp.status),
  ])
  |> search_any(resources.RtDeviceassociation, client, handle_response)
}

pub fn deviceassociation_search(
  sp: search_params.Deviceassociation,
  client: FhirClient,
  handle_response: fn(Result(List(resources.Deviceassociation), Err)) -> msg,
) -> Effect(msg) {
  deviceassociation_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) ->
        Ok({ bundle |> sansio.bundle_to_groupedresources }.deviceassociation)
      Error(error) -> Error(error)
    })
  })
}

pub fn devicedefinition_search_bundled(
  sp: search_params.Devicedefinition,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([
    #("identifier", sp.identifier),
    #("device-name", sp.device_name),
    #("organization", sp.organization),
    #("specification", sp.specification),
    #("type", sp.type_),
    #("specification-version", sp.specification_version),
    #("manufacturer", sp.manufacturer),
  ])
  |> search_any(resources.RtDevicedefinition, client, handle_response)
}

pub fn devicedefinition_search(
  sp: search_params.Devicedefinition,
  client: FhirClient,
  handle_response: fn(Result(List(resources.Devicedefinition), Err)) -> msg,
) -> Effect(msg) {
  devicedefinition_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) ->
        Ok({ bundle |> sansio.bundle_to_groupedresources }.devicedefinition)
      Error(error) -> Error(error)
    })
  })
}

pub fn devicedispense_search_bundled(
  sp: search_params.Devicedispense,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([
    #("identifier", sp.identifier),
    #("code", sp.code),
    #("subject", sp.subject),
    #("patient", sp.patient),
    #("status", sp.status),
  ])
  |> search_any(resources.RtDevicedispense, client, handle_response)
}

pub fn devicedispense_search(
  sp: search_params.Devicedispense,
  client: FhirClient,
  handle_response: fn(Result(List(resources.Devicedispense), Err)) -> msg,
) -> Effect(msg) {
  devicedispense_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) ->
        Ok({ bundle |> sansio.bundle_to_groupedresources }.devicedispense)
      Error(error) -> Error(error)
    })
  })
}

pub fn devicemetric_search_bundled(
  sp: search_params.Devicemetric,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([
    #("identifier", sp.identifier),
    #("category", sp.category),
    #("type", sp.type_),
    #("device", sp.device),
  ])
  |> search_any(resources.RtDevicemetric, client, handle_response)
}

pub fn devicemetric_search(
  sp: search_params.Devicemetric,
  client: FhirClient,
  handle_response: fn(Result(List(resources.Devicemetric), Err)) -> msg,
) -> Effect(msg) {
  devicemetric_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) ->
        Ok({ bundle |> sansio.bundle_to_groupedresources }.devicemetric)
      Error(error) -> Error(error)
    })
  })
}

pub fn devicerequest_search_bundled(
  sp: search_params.Devicerequest,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([
    #("insurance", sp.insurance),
    #("performer-code", sp.performer_code),
    #("requester", sp.requester),
    #("identifier", sp.identifier),
    #("code", sp.code),
    #("performer", sp.performer),
    #("event-date", sp.event_date),
    #("subject", sp.subject),
    #("instantiates-canonical", sp.instantiates_canonical),
    #("encounter", sp.encounter),
    #("authored-on", sp.authored_on),
    #("intent", sp.intent),
    #("group-identifier", sp.group_identifier),
    #("based-on", sp.based_on),
    #("patient", sp.patient),
    #("instantiates-uri", sp.instantiates_uri),
    #("device", sp.device),
    #("prior-request", sp.prior_request),
    #("status", sp.status),
  ])
  |> search_any(resources.RtDevicerequest, client, handle_response)
}

pub fn devicerequest_search(
  sp: search_params.Devicerequest,
  client: FhirClient,
  handle_response: fn(Result(List(resources.Devicerequest), Err)) -> msg,
) -> Effect(msg) {
  devicerequest_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) ->
        Ok({ bundle |> sansio.bundle_to_groupedresources }.devicerequest)
      Error(error) -> Error(error)
    })
  })
}

pub fn deviceusage_search_bundled(
  sp: search_params.Deviceusage,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([
    #("identifier", sp.identifier),
    #("patient", sp.patient),
    #("device", sp.device),
    #("status", sp.status),
  ])
  |> search_any(resources.RtDeviceusage, client, handle_response)
}

pub fn deviceusage_search(
  sp: search_params.Deviceusage,
  client: FhirClient,
  handle_response: fn(Result(List(resources.Deviceusage), Err)) -> msg,
) -> Effect(msg) {
  deviceusage_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) ->
        Ok({ bundle |> sansio.bundle_to_groupedresources }.deviceusage)
      Error(error) -> Error(error)
    })
  })
}

pub fn diagnosticreport_search_bundled(
  sp: search_params.Diagnosticreport,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([
    #("date", sp.date),
    #("identifier", sp.identifier),
    #("study", sp.study),
    #("code", sp.code),
    #("performer", sp.performer),
    #("subject", sp.subject),
    #("encounter", sp.encounter),
    #("media", sp.media),
    #("conclusion", sp.conclusion),
    #("result", sp.result),
    #("based-on", sp.based_on),
    #("patient", sp.patient),
    #("specimen", sp.specimen),
    #("category", sp.category),
    #("issued", sp.issued),
    #("results-interpreter", sp.results_interpreter),
    #("status", sp.status),
  ])
  |> search_any(resources.RtDiagnosticreport, client, handle_response)
}

pub fn diagnosticreport_search(
  sp: search_params.Diagnosticreport,
  client: FhirClient,
  handle_response: fn(Result(List(resources.Diagnosticreport), Err)) -> msg,
) -> Effect(msg) {
  diagnosticreport_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) ->
        Ok({ bundle |> sansio.bundle_to_groupedresources }.diagnosticreport)
      Error(error) -> Error(error)
    })
  })
}

pub fn documentreference_search_bundled(
  sp: search_params.Documentreference,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([
    #("date", sp.date),
    #("modality", sp.modality),
    #("subject", sp.subject),
    #("description", sp.description),
    #("language", sp.language),
    #("type", sp.type_),
    #("relation", sp.relation),
    #("setting", sp.setting),
    #("doc-status", sp.doc_status),
    #("based-on", sp.based_on),
    #("format-canonical", sp.format_canonical),
    #("patient", sp.patient),
    #("context", sp.context),
    #("relationship", sp.relationship),
    #("creation", sp.creation),
    #("identifier", sp.identifier),
    #("period", sp.period),
    #("event-code", sp.event_code),
    #("bodysite", sp.bodysite),
    #("custodian", sp.custodian),
    #("author", sp.author),
    #("format-code", sp.format_code),
    #("bodysite-reference", sp.bodysite_reference),
    #("format-uri", sp.format_uri),
    #("version", sp.version),
    #("attester", sp.attester),
    #("contenttype", sp.contenttype),
    #("event-reference", sp.event_reference),
    #("security-label", sp.security_label),
    #("location", sp.location),
    #("category", sp.category),
    #("relatesto", sp.relatesto),
    #("facility", sp.facility),
    #("status", sp.status),
  ])
  |> search_any(resources.RtDocumentreference, client, handle_response)
}

pub fn documentreference_search(
  sp: search_params.Documentreference,
  client: FhirClient,
  handle_response: fn(Result(List(resources.Documentreference), Err)) -> msg,
) -> Effect(msg) {
  documentreference_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) ->
        Ok({ bundle |> sansio.bundle_to_groupedresources }.documentreference)
      Error(error) -> Error(error)
    })
  })
}

pub fn encounter_search_bundled(
  sp: search_params.Encounter,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([
    #("date", sp.date),
    #("participant-type", sp.participant_type),
    #("subject", sp.subject),
    #("subject-status", sp.subject_status),
    #("appointment", sp.appointment),
    #("part-of", sp.part_of),
    #("type", sp.type_),
    #("participant", sp.participant),
    #("reason-code", sp.reason_code),
    #("based-on", sp.based_on),
    #("date-start", sp.date_start),
    #("patient", sp.patient),
    #("location-period", sp.location_period),
    #("special-arrangement", sp.special_arrangement),
    #("class", sp.class),
    #("identifier", sp.identifier),
    #("diagnosis-code", sp.diagnosis_code),
    #("practitioner", sp.practitioner),
    #("episode-of-care", sp.episode_of_care),
    #("length", sp.length),
    #("careteam", sp.careteam),
    #("end-date", sp.end_date),
    #("diagnosis-reference", sp.diagnosis_reference),
    #("reason-reference", sp.reason_reference),
    #("location", sp.location),
    #("service-provider", sp.service_provider),
    #("account", sp.account),
    #("status", sp.status),
  ])
  |> search_any(resources.RtEncounter, client, handle_response)
}

pub fn encounter_search(
  sp: search_params.Encounter,
  client: FhirClient,
  handle_response: fn(Result(List(resources.Encounter), Err)) -> msg,
) -> Effect(msg) {
  encounter_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) ->
        Ok({ bundle |> sansio.bundle_to_groupedresources }.encounter)
      Error(error) -> Error(error)
    })
  })
}

pub fn encounterhistory_search_bundled(
  sp: search_params.Encounterhistory,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([
    #("identifier", sp.identifier),
    #("patient", sp.patient),
    #("subject", sp.subject),
    #("encounter", sp.encounter),
    #("status", sp.status),
  ])
  |> search_any(resources.RtEncounterhistory, client, handle_response)
}

pub fn encounterhistory_search(
  sp: search_params.Encounterhistory,
  client: FhirClient,
  handle_response: fn(Result(List(resources.Encounterhistory), Err)) -> msg,
) -> Effect(msg) {
  encounterhistory_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) ->
        Ok({ bundle |> sansio.bundle_to_groupedresources }.encounterhistory)
      Error(error) -> Error(error)
    })
  })
}

pub fn endpoint_search_bundled(
  sp: search_params.Endpoint,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([
    #("payload-type", sp.payload_type),
    #("identifier", sp.identifier),
    #("connection-type", sp.connection_type),
    #("organization", sp.organization),
    #("name", sp.name),
    #("status", sp.status),
  ])
  |> search_any(resources.RtEndpoint, client, handle_response)
}

pub fn endpoint_search(
  sp: search_params.Endpoint,
  client: FhirClient,
  handle_response: fn(Result(List(resources.Endpoint), Err)) -> msg,
) -> Effect(msg) {
  endpoint_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) -> Ok({ bundle |> sansio.bundle_to_groupedresources }.endpoint)
      Error(error) -> Error(error)
    })
  })
}

pub fn enrollmentrequest_search_bundled(
  sp: search_params.Enrollmentrequest,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([
    #("identifier", sp.identifier),
    #("patient", sp.patient),
    #("subject", sp.subject),
    #("status", sp.status),
  ])
  |> search_any(resources.RtEnrollmentrequest, client, handle_response)
}

pub fn enrollmentrequest_search(
  sp: search_params.Enrollmentrequest,
  client: FhirClient,
  handle_response: fn(Result(List(resources.Enrollmentrequest), Err)) -> msg,
) -> Effect(msg) {
  enrollmentrequest_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) ->
        Ok({ bundle |> sansio.bundle_to_groupedresources }.enrollmentrequest)
      Error(error) -> Error(error)
    })
  })
}

pub fn enrollmentresponse_search_bundled(
  sp: search_params.Enrollmentresponse,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([
    #("identifier", sp.identifier),
    #("request", sp.request),
    #("status", sp.status),
  ])
  |> search_any(resources.RtEnrollmentresponse, client, handle_response)
}

pub fn enrollmentresponse_search(
  sp: search_params.Enrollmentresponse,
  client: FhirClient,
  handle_response: fn(Result(List(resources.Enrollmentresponse), Err)) -> msg,
) -> Effect(msg) {
  enrollmentresponse_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) ->
        Ok({ bundle |> sansio.bundle_to_groupedresources }.enrollmentresponse)
      Error(error) -> Error(error)
    })
  })
}

pub fn episodeofcare_search_bundled(
  sp: search_params.Episodeofcare,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([
    #("date", sp.date),
    #("identifier", sp.identifier),
    #("diagnosis-code", sp.diagnosis_code),
    #("diagnosis-reference", sp.diagnosis_reference),
    #("patient", sp.patient),
    #("organization", sp.organization),
    #("reason-reference", sp.reason_reference),
    #("type", sp.type_),
    #("care-manager", sp.care_manager),
    #("reason-code", sp.reason_code),
    #("incoming-referral", sp.incoming_referral),
    #("status", sp.status),
  ])
  |> search_any(resources.RtEpisodeofcare, client, handle_response)
}

pub fn episodeofcare_search(
  sp: search_params.Episodeofcare,
  client: FhirClient,
  handle_response: fn(Result(List(resources.Episodeofcare), Err)) -> msg,
) -> Effect(msg) {
  episodeofcare_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) ->
        Ok({ bundle |> sansio.bundle_to_groupedresources }.episodeofcare)
      Error(error) -> Error(error)
    })
  })
}

pub fn eventdefinition_search_bundled(
  sp: search_params.Eventdefinition,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([
    #("date", sp.date),
    #("identifier", sp.identifier),
    #("successor", sp.successor),
    #("context-type-value", sp.context_type_value),
    #("jurisdiction", sp.jurisdiction),
    #("derived-from", sp.derived_from),
    #("description", sp.description),
    #("context-type", sp.context_type),
    #("predecessor", sp.predecessor),
    #("composed-of", sp.composed_of),
    #("title", sp.title),
    #("version", sp.version),
    #("url", sp.url),
    #("context-quantity", sp.context_quantity),
    #("depends-on", sp.depends_on),
    #("effective", sp.effective),
    #("context", sp.context),
    #("name", sp.name),
    #("publisher", sp.publisher),
    #("topic", sp.topic),
    #("context-type-quantity", sp.context_type_quantity),
    #("status", sp.status),
  ])
  |> search_any(resources.RtEventdefinition, client, handle_response)
}

pub fn eventdefinition_search(
  sp: search_params.Eventdefinition,
  client: FhirClient,
  handle_response: fn(Result(List(resources.Eventdefinition), Err)) -> msg,
) -> Effect(msg) {
  eventdefinition_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) ->
        Ok({ bundle |> sansio.bundle_to_groupedresources }.eventdefinition)
      Error(error) -> Error(error)
    })
  })
}

pub fn evidence_search_bundled(
  sp: search_params.Evidence,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([
    #("date", sp.date),
    #("identifier", sp.identifier),
    #("context-type-value", sp.context_type_value),
    #("description", sp.description),
    #("context-type", sp.context_type),
    #("title", sp.title),
    #("version", sp.version),
    #("url", sp.url),
    #("context-quantity", sp.context_quantity),
    #("context", sp.context),
    #("publisher", sp.publisher),
    #("context-type-quantity", sp.context_type_quantity),
    #("status", sp.status),
  ])
  |> search_any(resources.RtEvidence, client, handle_response)
}

pub fn evidence_search(
  sp: search_params.Evidence,
  client: FhirClient,
  handle_response: fn(Result(List(resources.Evidence), Err)) -> msg,
) -> Effect(msg) {
  evidence_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) -> Ok({ bundle |> sansio.bundle_to_groupedresources }.evidence)
      Error(error) -> Error(error)
    })
  })
}

pub fn evidencereport_search_bundled(
  sp: search_params.Evidencereport,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([
    #("context-quantity", sp.context_quantity),
    #("identifier", sp.identifier),
    #("context-type-value", sp.context_type_value),
    #("context", sp.context),
    #("publisher", sp.publisher),
    #("context-type", sp.context_type),
    #("context-type-quantity", sp.context_type_quantity),
    #("url", sp.url),
    #("status", sp.status),
  ])
  |> search_any(resources.RtEvidencereport, client, handle_response)
}

pub fn evidencereport_search(
  sp: search_params.Evidencereport,
  client: FhirClient,
  handle_response: fn(Result(List(resources.Evidencereport), Err)) -> msg,
) -> Effect(msg) {
  evidencereport_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) ->
        Ok({ bundle |> sansio.bundle_to_groupedresources }.evidencereport)
      Error(error) -> Error(error)
    })
  })
}

pub fn evidencevariable_search_bundled(
  sp: search_params.Evidencevariable,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([
    #("date", sp.date),
    #("identifier", sp.identifier),
    #("successor", sp.successor),
    #("context-type-value", sp.context_type_value),
    #("derived-from", sp.derived_from),
    #("description", sp.description),
    #("context-type", sp.context_type),
    #("predecessor", sp.predecessor),
    #("composed-of", sp.composed_of),
    #("title", sp.title),
    #("version", sp.version),
    #("url", sp.url),
    #("context-quantity", sp.context_quantity),
    #("depends-on", sp.depends_on),
    #("context", sp.context),
    #("name", sp.name),
    #("publisher", sp.publisher),
    #("topic", sp.topic),
    #("context-type-quantity", sp.context_type_quantity),
    #("status", sp.status),
  ])
  |> search_any(resources.RtEvidencevariable, client, handle_response)
}

pub fn evidencevariable_search(
  sp: search_params.Evidencevariable,
  client: FhirClient,
  handle_response: fn(Result(List(resources.Evidencevariable), Err)) -> msg,
) -> Effect(msg) {
  evidencevariable_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) ->
        Ok({ bundle |> sansio.bundle_to_groupedresources }.evidencevariable)
      Error(error) -> Error(error)
    })
  })
}

pub fn examplescenario_search_bundled(
  sp: search_params.Examplescenario,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([
    #("date", sp.date),
    #("identifier", sp.identifier),
    #("context-type-value", sp.context_type_value),
    #("jurisdiction", sp.jurisdiction),
    #("context-type", sp.context_type),
    #("version", sp.version),
    #("url", sp.url),
    #("context-quantity", sp.context_quantity),
    #("context", sp.context),
    #("name", sp.name),
    #("publisher", sp.publisher),
    #("context-type-quantity", sp.context_type_quantity),
    #("status", sp.status),
  ])
  |> search_any(resources.RtExamplescenario, client, handle_response)
}

pub fn examplescenario_search(
  sp: search_params.Examplescenario,
  client: FhirClient,
  handle_response: fn(Result(List(resources.Examplescenario), Err)) -> msg,
) -> Effect(msg) {
  examplescenario_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) ->
        Ok({ bundle |> sansio.bundle_to_groupedresources }.examplescenario)
      Error(error) -> Error(error)
    })
  })
}

pub fn explanationofbenefit_search_bundled(
  sp: search_params.Explanationofbenefit,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([
    #("care-team", sp.care_team),
    #("coverage", sp.coverage),
    #("identifier", sp.identifier),
    #("created", sp.created),
    #("encounter", sp.encounter),
    #("payee", sp.payee),
    #("disposition", sp.disposition),
    #("provider", sp.provider),
    #("patient", sp.patient),
    #("detail-udi", sp.detail_udi),
    #("claim", sp.claim),
    #("enterer", sp.enterer),
    #("procedure-udi", sp.procedure_udi),
    #("subdetail-udi", sp.subdetail_udi),
    #("facility", sp.facility),
    #("item-udi", sp.item_udi),
    #("status", sp.status),
  ])
  |> search_any(resources.RtExplanationofbenefit, client, handle_response)
}

pub fn explanationofbenefit_search(
  sp: search_params.Explanationofbenefit,
  client: FhirClient,
  handle_response: fn(Result(List(resources.Explanationofbenefit), Err)) -> msg,
) -> Effect(msg) {
  explanationofbenefit_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) ->
        Ok({ bundle |> sansio.bundle_to_groupedresources }.explanationofbenefit)
      Error(error) -> Error(error)
    })
  })
}

pub fn familymemberhistory_search_bundled(
  sp: search_params.Familymemberhistory,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([
    #("date", sp.date),
    #("identifier", sp.identifier),
    #("code", sp.code),
    #("patient", sp.patient),
    #("sex", sp.sex),
    #("instantiates-canonical", sp.instantiates_canonical),
    #("instantiates-uri", sp.instantiates_uri),
    #("relationship", sp.relationship),
    #("status", sp.status),
  ])
  |> search_any(resources.RtFamilymemberhistory, client, handle_response)
}

pub fn familymemberhistory_search(
  sp: search_params.Familymemberhistory,
  client: FhirClient,
  handle_response: fn(Result(List(resources.Familymemberhistory), Err)) -> msg,
) -> Effect(msg) {
  familymemberhistory_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) ->
        Ok({ bundle |> sansio.bundle_to_groupedresources }.familymemberhistory)
      Error(error) -> Error(error)
    })
  })
}

pub fn flag_search_bundled(
  sp: search_params.Flag,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([
    #("date", sp.date),
    #("identifier", sp.identifier),
    #("author", sp.author),
    #("patient", sp.patient),
    #("subject", sp.subject),
    #("encounter", sp.encounter),
    #("category", sp.category),
    #("status", sp.status),
  ])
  |> search_any(resources.RtFlag, client, handle_response)
}

pub fn flag_search(
  sp: search_params.Flag,
  client: FhirClient,
  handle_response: fn(Result(List(resources.Flag), Err)) -> msg,
) -> Effect(msg) {
  flag_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) -> Ok({ bundle |> sansio.bundle_to_groupedresources }.flag)
      Error(error) -> Error(error)
    })
  })
}

pub fn formularyitem_search_bundled(
  sp: search_params.Formularyitem,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([
    #("identifier", sp.identifier),
    #("code", sp.code),
  ])
  |> search_any(resources.RtFormularyitem, client, handle_response)
}

pub fn formularyitem_search(
  sp: search_params.Formularyitem,
  client: FhirClient,
  handle_response: fn(Result(List(resources.Formularyitem), Err)) -> msg,
) -> Effect(msg) {
  formularyitem_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) ->
        Ok({ bundle |> sansio.bundle_to_groupedresources }.formularyitem)
      Error(error) -> Error(error)
    })
  })
}

pub fn genomicstudy_search_bundled(
  sp: search_params.Genomicstudy,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([
    #("identifier", sp.identifier),
    #("patient", sp.patient),
    #("subject", sp.subject),
    #("focus", sp.focus),
    #("status", sp.status),
  ])
  |> search_any(resources.RtGenomicstudy, client, handle_response)
}

pub fn genomicstudy_search(
  sp: search_params.Genomicstudy,
  client: FhirClient,
  handle_response: fn(Result(List(resources.Genomicstudy), Err)) -> msg,
) -> Effect(msg) {
  genomicstudy_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) ->
        Ok({ bundle |> sansio.bundle_to_groupedresources }.genomicstudy)
      Error(error) -> Error(error)
    })
  })
}

pub fn goal_search_bundled(
  sp: search_params.Goal,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([
    #("target-measure", sp.target_measure),
    #("identifier", sp.identifier),
    #("addresses", sp.addresses),
    #("lifecycle-status", sp.lifecycle_status),
    #("achievement-status", sp.achievement_status),
    #("patient", sp.patient),
    #("subject", sp.subject),
    #("description", sp.description),
    #("start-date", sp.start_date),
    #("category", sp.category),
    #("target-date", sp.target_date),
  ])
  |> search_any(resources.RtGoal, client, handle_response)
}

pub fn goal_search(
  sp: search_params.Goal,
  client: FhirClient,
  handle_response: fn(Result(List(resources.Goal), Err)) -> msg,
) -> Effect(msg) {
  goal_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) -> Ok({ bundle |> sansio.bundle_to_groupedresources }.goal)
      Error(error) -> Error(error)
    })
  })
}

pub fn graphdefinition_search_bundled(
  sp: search_params.Graphdefinition,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([
    #("date", sp.date),
    #("identifier", sp.identifier),
    #("context-type-value", sp.context_type_value),
    #("jurisdiction", sp.jurisdiction),
    #("start", sp.start),
    #("description", sp.description),
    #("context-type", sp.context_type),
    #("version", sp.version),
    #("url", sp.url),
    #("context-quantity", sp.context_quantity),
    #("context", sp.context),
    #("name", sp.name),
    #("publisher", sp.publisher),
    #("context-type-quantity", sp.context_type_quantity),
    #("status", sp.status),
  ])
  |> search_any(resources.RtGraphdefinition, client, handle_response)
}

pub fn graphdefinition_search(
  sp: search_params.Graphdefinition,
  client: FhirClient,
  handle_response: fn(Result(List(resources.Graphdefinition), Err)) -> msg,
) -> Effect(msg) {
  graphdefinition_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) ->
        Ok({ bundle |> sansio.bundle_to_groupedresources }.graphdefinition)
      Error(error) -> Error(error)
    })
  })
}

pub fn group_search_bundled(
  sp: search_params.Group,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([
    #("identifier", sp.identifier),
    #("characteristic-value", sp.characteristic_value),
    #("managing-entity", sp.managing_entity),
    #("code", sp.code),
    #("member", sp.member),
    #("name", sp.name),
    #("exclude", sp.exclude),
    #("membership", sp.membership),
    #("type", sp.type_),
    #("characteristic-reference", sp.characteristic_reference),
    #("value", sp.value),
    #("characteristic", sp.characteristic),
  ])
  |> search_any(resources.RtGroup, client, handle_response)
}

pub fn group_search(
  sp: search_params.Group,
  client: FhirClient,
  handle_response: fn(Result(List(resources.Group), Err)) -> msg,
) -> Effect(msg) {
  group_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) -> Ok({ bundle |> sansio.bundle_to_groupedresources }.group)
      Error(error) -> Error(error)
    })
  })
}

pub fn guidanceresponse_search_bundled(
  sp: search_params.Guidanceresponse,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([
    #("identifier", sp.identifier),
    #("request", sp.request),
    #("patient", sp.patient),
    #("subject", sp.subject),
    #("status", sp.status),
  ])
  |> search_any(resources.RtGuidanceresponse, client, handle_response)
}

pub fn guidanceresponse_search(
  sp: search_params.Guidanceresponse,
  client: FhirClient,
  handle_response: fn(Result(List(resources.Guidanceresponse), Err)) -> msg,
) -> Effect(msg) {
  guidanceresponse_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) ->
        Ok({ bundle |> sansio.bundle_to_groupedresources }.guidanceresponse)
      Error(error) -> Error(error)
    })
  })
}

pub fn healthcareservice_search_bundled(
  sp: search_params.Healthcareservice,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([
    #("identifier", sp.identifier),
    #("specialty", sp.specialty),
    #("service-category", sp.service_category),
    #("service-type", sp.service_type),
    #("active", sp.active),
    #("eligibility", sp.eligibility),
    #("program", sp.program),
    #("characteristic", sp.characteristic),
    #("endpoint", sp.endpoint),
    #("coverage-area", sp.coverage_area),
    #("organization", sp.organization),
    #("offered-in", sp.offered_in),
    #("name", sp.name),
    #("location", sp.location),
    #("communication", sp.communication),
  ])
  |> search_any(resources.RtHealthcareservice, client, handle_response)
}

pub fn healthcareservice_search(
  sp: search_params.Healthcareservice,
  client: FhirClient,
  handle_response: fn(Result(List(resources.Healthcareservice), Err)) -> msg,
) -> Effect(msg) {
  healthcareservice_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) ->
        Ok({ bundle |> sansio.bundle_to_groupedresources }.healthcareservice)
      Error(error) -> Error(error)
    })
  })
}

pub fn imagingselection_search_bundled(
  sp: search_params.Imagingselection,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([
    #("identifier", sp.identifier),
    #("body-structure", sp.body_structure),
    #("based-on", sp.based_on),
    #("code", sp.code),
    #("subject", sp.subject),
    #("patient", sp.patient),
    #("derived-from", sp.derived_from),
    #("issued", sp.issued),
    #("body-site", sp.body_site),
    #("study-uid", sp.study_uid),
    #("status", sp.status),
  ])
  |> search_any(resources.RtImagingselection, client, handle_response)
}

pub fn imagingselection_search(
  sp: search_params.Imagingselection,
  client: FhirClient,
  handle_response: fn(Result(List(resources.Imagingselection), Err)) -> msg,
) -> Effect(msg) {
  imagingselection_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) ->
        Ok({ bundle |> sansio.bundle_to_groupedresources }.imagingselection)
      Error(error) -> Error(error)
    })
  })
}

pub fn imagingstudy_search_bundled(
  sp: search_params.Imagingstudy,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([
    #("identifier", sp.identifier),
    #("reason", sp.reason),
    #("dicom-class", sp.dicom_class),
    #("instance", sp.instance),
    #("modality", sp.modality),
    #("performer", sp.performer),
    #("subject", sp.subject),
    #("started", sp.started),
    #("encounter", sp.encounter),
    #("referrer", sp.referrer),
    #("body-structure", sp.body_structure),
    #("endpoint", sp.endpoint),
    #("based-on", sp.based_on),
    #("patient", sp.patient),
    #("series", sp.series),
    #("body-site", sp.body_site),
    #("status", sp.status),
  ])
  |> search_any(resources.RtImagingstudy, client, handle_response)
}

pub fn imagingstudy_search(
  sp: search_params.Imagingstudy,
  client: FhirClient,
  handle_response: fn(Result(List(resources.Imagingstudy), Err)) -> msg,
) -> Effect(msg) {
  imagingstudy_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) ->
        Ok({ bundle |> sansio.bundle_to_groupedresources }.imagingstudy)
      Error(error) -> Error(error)
    })
  })
}

pub fn immunization_search_bundled(
  sp: search_params.Immunization,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([
    #("date", sp.date),
    #("identifier", sp.identifier),
    #("performer", sp.performer),
    #("reaction", sp.reaction),
    #("lot-number", sp.lot_number),
    #("status-reason", sp.status_reason),
    #("reason-code", sp.reason_code),
    #("manufacturer", sp.manufacturer),
    #("target-disease", sp.target_disease),
    #("patient", sp.patient),
    #("series", sp.series),
    #("vaccine-code", sp.vaccine_code),
    #("reason-reference", sp.reason_reference),
    #("location", sp.location),
    #("reaction-date", sp.reaction_date),
    #("status", sp.status),
  ])
  |> search_any(resources.RtImmunization, client, handle_response)
}

pub fn immunization_search(
  sp: search_params.Immunization,
  client: FhirClient,
  handle_response: fn(Result(List(resources.Immunization), Err)) -> msg,
) -> Effect(msg) {
  immunization_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) ->
        Ok({ bundle |> sansio.bundle_to_groupedresources }.immunization)
      Error(error) -> Error(error)
    })
  })
}

pub fn immunizationevaluation_search_bundled(
  sp: search_params.Immunizationevaluation,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([
    #("date", sp.date),
    #("identifier", sp.identifier),
    #("target-disease", sp.target_disease),
    #("patient", sp.patient),
    #("dose-status", sp.dose_status),
    #("immunization-event", sp.immunization_event),
    #("status", sp.status),
  ])
  |> search_any(resources.RtImmunizationevaluation, client, handle_response)
}

pub fn immunizationevaluation_search(
  sp: search_params.Immunizationevaluation,
  client: FhirClient,
  handle_response: fn(Result(List(resources.Immunizationevaluation), Err)) ->
    msg,
) -> Effect(msg) {
  immunizationevaluation_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) ->
        Ok(
          { bundle |> sansio.bundle_to_groupedresources }.immunizationevaluation,
        )
      Error(error) -> Error(error)
    })
  })
}

pub fn immunizationrecommendation_search_bundled(
  sp: search_params.Immunizationrecommendation,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([
    #("date", sp.date),
    #("identifier", sp.identifier),
    #("target-disease", sp.target_disease),
    #("patient", sp.patient),
    #("vaccine-type", sp.vaccine_type),
    #("information", sp.information),
    #("support", sp.support),
    #("status", sp.status),
  ])
  |> search_any(resources.RtImmunizationrecommendation, client, handle_response)
}

pub fn immunizationrecommendation_search(
  sp: search_params.Immunizationrecommendation,
  client: FhirClient,
  handle_response: fn(Result(List(resources.Immunizationrecommendation), Err)) ->
    msg,
) -> Effect(msg) {
  immunizationrecommendation_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) ->
        Ok(
          { bundle |> sansio.bundle_to_groupedresources }.immunizationrecommendation,
        )
      Error(error) -> Error(error)
    })
  })
}

pub fn implementationguide_search_bundled(
  sp: search_params.Implementationguide,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([
    #("date", sp.date),
    #("identifier", sp.identifier),
    #("context-type-value", sp.context_type_value),
    #("resource", sp.resource),
    #("jurisdiction", sp.jurisdiction),
    #("description", sp.description),
    #("context-type", sp.context_type),
    #("experimental", sp.experimental),
    #("global", sp.global),
    #("title", sp.title),
    #("version", sp.version),
    #("url", sp.url),
    #("context-quantity", sp.context_quantity),
    #("depends-on", sp.depends_on),
    #("context", sp.context),
    #("name", sp.name),
    #("publisher", sp.publisher),
    #("context-type-quantity", sp.context_type_quantity),
    #("status", sp.status),
  ])
  |> search_any(resources.RtImplementationguide, client, handle_response)
}

pub fn implementationguide_search(
  sp: search_params.Implementationguide,
  client: FhirClient,
  handle_response: fn(Result(List(resources.Implementationguide), Err)) -> msg,
) -> Effect(msg) {
  implementationguide_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) ->
        Ok({ bundle |> sansio.bundle_to_groupedresources }.implementationguide)
      Error(error) -> Error(error)
    })
  })
}

pub fn ingredient_search_bundled(
  sp: search_params.Ingredient,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([
    #("identifier", sp.identifier),
    #("role", sp.role),
    #("substance", sp.substance),
    #("strength-concentration-ratio", sp.strength_concentration_ratio),
    #("for", sp.for),
    #("substance-code", sp.substance_code),
    #("strength-concentration-quantity", sp.strength_concentration_quantity),
    #("manufacturer", sp.manufacturer),
    #("substance-definition", sp.substance_definition),
    #("function", sp.function),
    #("strength-presentation-ratio", sp.strength_presentation_ratio),
    #("strength-presentation-quantity", sp.strength_presentation_quantity),
    #("status", sp.status),
  ])
  |> search_any(resources.RtIngredient, client, handle_response)
}

pub fn ingredient_search(
  sp: search_params.Ingredient,
  client: FhirClient,
  handle_response: fn(Result(List(resources.Ingredient), Err)) -> msg,
) -> Effect(msg) {
  ingredient_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) ->
        Ok({ bundle |> sansio.bundle_to_groupedresources }.ingredient)
      Error(error) -> Error(error)
    })
  })
}

pub fn insuranceplan_search_bundled(
  sp: search_params.Insuranceplan,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([
    #("identifier", sp.identifier),
    #("address", sp.address),
    #("address-state", sp.address_state),
    #("owned-by", sp.owned_by),
    #("type", sp.type_),
    #("address-postalcode", sp.address_postalcode),
    #("address-country", sp.address_country),
    #("administered-by", sp.administered_by),
    #("endpoint", sp.endpoint),
    #("phonetic", sp.phonetic),
    #("address-use", sp.address_use),
    #("name", sp.name),
    #("address-city", sp.address_city),
    #("status", sp.status),
  ])
  |> search_any(resources.RtInsuranceplan, client, handle_response)
}

pub fn insuranceplan_search(
  sp: search_params.Insuranceplan,
  client: FhirClient,
  handle_response: fn(Result(List(resources.Insuranceplan), Err)) -> msg,
) -> Effect(msg) {
  insuranceplan_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) ->
        Ok({ bundle |> sansio.bundle_to_groupedresources }.insuranceplan)
      Error(error) -> Error(error)
    })
  })
}

pub fn inventoryitem_search_bundled(
  sp: search_params.Inventoryitem,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([
    #("identifier", sp.identifier),
    #("code", sp.code),
    #("subject", sp.subject),
    #("status", sp.status),
  ])
  |> search_any(resources.RtInventoryitem, client, handle_response)
}

pub fn inventoryitem_search(
  sp: search_params.Inventoryitem,
  client: FhirClient,
  handle_response: fn(Result(List(resources.Inventoryitem), Err)) -> msg,
) -> Effect(msg) {
  inventoryitem_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) ->
        Ok({ bundle |> sansio.bundle_to_groupedresources }.inventoryitem)
      Error(error) -> Error(error)
    })
  })
}

pub fn inventoryreport_search_bundled(
  sp: search_params.Inventoryreport,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([
    #("item-reference", sp.item_reference),
    #("identifier", sp.identifier),
    #("item", sp.item),
    #("status", sp.status),
  ])
  |> search_any(resources.RtInventoryreport, client, handle_response)
}

pub fn inventoryreport_search(
  sp: search_params.Inventoryreport,
  client: FhirClient,
  handle_response: fn(Result(List(resources.Inventoryreport), Err)) -> msg,
) -> Effect(msg) {
  inventoryreport_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) ->
        Ok({ bundle |> sansio.bundle_to_groupedresources }.inventoryreport)
      Error(error) -> Error(error)
    })
  })
}

pub fn invoice_search_bundled(
  sp: search_params.Invoice,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([
    #("date", sp.date),
    #("identifier", sp.identifier),
    #("totalgross", sp.totalgross),
    #("participant-role", sp.participant_role),
    #("subject", sp.subject),
    #("type", sp.type_),
    #("issuer", sp.issuer),
    #("participant", sp.participant),
    #("totalnet", sp.totalnet),
    #("patient", sp.patient),
    #("recipient", sp.recipient),
    #("account", sp.account),
    #("status", sp.status),
  ])
  |> search_any(resources.RtInvoice, client, handle_response)
}

pub fn invoice_search(
  sp: search_params.Invoice,
  client: FhirClient,
  handle_response: fn(Result(List(resources.Invoice), Err)) -> msg,
) -> Effect(msg) {
  invoice_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) -> Ok({ bundle |> sansio.bundle_to_groupedresources }.invoice)
      Error(error) -> Error(error)
    })
  })
}

pub fn library_search_bundled(
  sp: search_params.Library,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([
    #("date", sp.date),
    #("identifier", sp.identifier),
    #("successor", sp.successor),
    #("context-type-value", sp.context_type_value),
    #("jurisdiction", sp.jurisdiction),
    #("derived-from", sp.derived_from),
    #("description", sp.description),
    #("context-type", sp.context_type),
    #("predecessor", sp.predecessor),
    #("composed-of", sp.composed_of),
    #("title", sp.title),
    #("type", sp.type_),
    #("version", sp.version),
    #("url", sp.url),
    #("context-quantity", sp.context_quantity),
    #("depends-on", sp.depends_on),
    #("effective", sp.effective),
    #("context", sp.context),
    #("name", sp.name),
    #("publisher", sp.publisher),
    #("topic", sp.topic),
    #("content-type", sp.content_type),
    #("context-type-quantity", sp.context_type_quantity),
    #("status", sp.status),
  ])
  |> search_any(resources.RtLibrary, client, handle_response)
}

pub fn library_search(
  sp: search_params.Library,
  client: FhirClient,
  handle_response: fn(Result(List(resources.Library), Err)) -> msg,
) -> Effect(msg) {
  library_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) -> Ok({ bundle |> sansio.bundle_to_groupedresources }.library)
      Error(error) -> Error(error)
    })
  })
}

pub fn linkage_search_bundled(
  sp: search_params.Linkage,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([
    #("item", sp.item),
    #("author", sp.author),
    #("source", sp.source),
  ])
  |> search_any(resources.RtLinkage, client, handle_response)
}

pub fn linkage_search(
  sp: search_params.Linkage,
  client: FhirClient,
  handle_response: fn(Result(List(resources.Linkage), Err)) -> msg,
) -> Effect(msg) {
  linkage_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) -> Ok({ bundle |> sansio.bundle_to_groupedresources }.linkage)
      Error(error) -> Error(error)
    })
  })
}

pub fn listfhir_search_bundled(
  sp: search_params.Listfhir,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([
    #("date", sp.date),
    #("identifier", sp.identifier),
    #("empty-reason", sp.empty_reason),
    #("item", sp.item),
    #("code", sp.code),
    #("notes", sp.notes),
    #("patient", sp.patient),
    #("subject", sp.subject),
    #("encounter", sp.encounter),
    #("source", sp.source),
    #("title", sp.title),
    #("status", sp.status),
  ])
  |> search_any(resources.RtListfhir, client, handle_response)
}

pub fn listfhir_search(
  sp: search_params.Listfhir,
  client: FhirClient,
  handle_response: fn(Result(List(resources.Listfhir), Err)) -> msg,
) -> Effect(msg) {
  listfhir_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) -> Ok({ bundle |> sansio.bundle_to_groupedresources }.listfhir)
      Error(error) -> Error(error)
    })
  })
}

pub fn location_search_bundled(
  sp: search_params.Location,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([
    #("identifier", sp.identifier),
    #("partof", sp.partof),
    #("address", sp.address),
    #("address-state", sp.address_state),
    #("operational-status", sp.operational_status),
    #("type", sp.type_),
    #("address-postalcode", sp.address_postalcode),
    #("characteristic", sp.characteristic),
    #("address-country", sp.address_country),
    #("endpoint", sp.endpoint),
    #("contains", sp.contains),
    #("organization", sp.organization),
    #("address-use", sp.address_use),
    #("name", sp.name),
    #("near", sp.near),
    #("address-city", sp.address_city),
    #("status", sp.status),
  ])
  |> search_any(resources.RtLocation, client, handle_response)
}

pub fn location_search(
  sp: search_params.Location,
  client: FhirClient,
  handle_response: fn(Result(List(resources.Location), Err)) -> msg,
) -> Effect(msg) {
  location_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) -> Ok({ bundle |> sansio.bundle_to_groupedresources }.location)
      Error(error) -> Error(error)
    })
  })
}

pub fn manufactureditemdefinition_search_bundled(
  sp: search_params.Manufactureditemdefinition,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([
    #("identifier", sp.identifier),
    #("ingredient", sp.ingredient),
    #("name", sp.name),
    #("dose-form", sp.dose_form),
    #("status", sp.status),
  ])
  |> search_any(resources.RtManufactureditemdefinition, client, handle_response)
}

pub fn manufactureditemdefinition_search(
  sp: search_params.Manufactureditemdefinition,
  client: FhirClient,
  handle_response: fn(Result(List(resources.Manufactureditemdefinition), Err)) ->
    msg,
) -> Effect(msg) {
  manufactureditemdefinition_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) ->
        Ok(
          { bundle |> sansio.bundle_to_groupedresources }.manufactureditemdefinition,
        )
      Error(error) -> Error(error)
    })
  })
}

pub fn measure_search_bundled(
  sp: search_params.Measure,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([
    #("date", sp.date),
    #("identifier", sp.identifier),
    #("successor", sp.successor),
    #("context-type-value", sp.context_type_value),
    #("jurisdiction", sp.jurisdiction),
    #("derived-from", sp.derived_from),
    #("description", sp.description),
    #("context-type", sp.context_type),
    #("predecessor", sp.predecessor),
    #("composed-of", sp.composed_of),
    #("title", sp.title),
    #("version", sp.version),
    #("url", sp.url),
    #("context-quantity", sp.context_quantity),
    #("depends-on", sp.depends_on),
    #("effective", sp.effective),
    #("context", sp.context),
    #("name", sp.name),
    #("publisher", sp.publisher),
    #("topic", sp.topic),
    #("context-type-quantity", sp.context_type_quantity),
    #("status", sp.status),
  ])
  |> search_any(resources.RtMeasure, client, handle_response)
}

pub fn measure_search(
  sp: search_params.Measure,
  client: FhirClient,
  handle_response: fn(Result(List(resources.Measure), Err)) -> msg,
) -> Effect(msg) {
  measure_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) -> Ok({ bundle |> sansio.bundle_to_groupedresources }.measure)
      Error(error) -> Error(error)
    })
  })
}

pub fn measurereport_search_bundled(
  sp: search_params.Measurereport,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([
    #("date", sp.date),
    #("identifier", sp.identifier),
    #("period", sp.period),
    #("measure", sp.measure),
    #("patient", sp.patient),
    #("subject", sp.subject),
    #("reporter", sp.reporter),
    #("location", sp.location),
    #("evaluated-resource", sp.evaluated_resource),
    #("status", sp.status),
  ])
  |> search_any(resources.RtMeasurereport, client, handle_response)
}

pub fn measurereport_search(
  sp: search_params.Measurereport,
  client: FhirClient,
  handle_response: fn(Result(List(resources.Measurereport), Err)) -> msg,
) -> Effect(msg) {
  measurereport_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) ->
        Ok({ bundle |> sansio.bundle_to_groupedresources }.measurereport)
      Error(error) -> Error(error)
    })
  })
}

pub fn medication_search_bundled(
  sp: search_params.Medication,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([
    #("ingredient-code", sp.ingredient_code),
    #("identifier", sp.identifier),
    #("code", sp.code),
    #("ingredient", sp.ingredient),
    #("form", sp.form),
    #("lot-number", sp.lot_number),
    #("serial-number", sp.serial_number),
    #("expiration-date", sp.expiration_date),
    #("marketingauthorizationholder", sp.marketingauthorizationholder),
    #("status", sp.status),
  ])
  |> search_any(resources.RtMedication, client, handle_response)
}

pub fn medication_search(
  sp: search_params.Medication,
  client: FhirClient,
  handle_response: fn(Result(List(resources.Medication), Err)) -> msg,
) -> Effect(msg) {
  medication_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) ->
        Ok({ bundle |> sansio.bundle_to_groupedresources }.medication)
      Error(error) -> Error(error)
    })
  })
}

pub fn medicationadministration_search_bundled(
  sp: search_params.Medicationadministration,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([
    #("date", sp.date),
    #("identifier", sp.identifier),
    #("request", sp.request),
    #("code", sp.code),
    #("performer", sp.performer),
    #("performer-device-code", sp.performer_device_code),
    #("subject", sp.subject),
    #("medication", sp.medication),
    #("reason-given", sp.reason_given),
    #("encounter", sp.encounter),
    #("reason-given-code", sp.reason_given_code),
    #("patient", sp.patient),
    #("reason-not-given", sp.reason_not_given),
    #("device", sp.device),
    #("status", sp.status),
  ])
  |> search_any(resources.RtMedicationadministration, client, handle_response)
}

pub fn medicationadministration_search(
  sp: search_params.Medicationadministration,
  client: FhirClient,
  handle_response: fn(Result(List(resources.Medicationadministration), Err)) ->
    msg,
) -> Effect(msg) {
  medicationadministration_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) ->
        Ok(
          { bundle |> sansio.bundle_to_groupedresources }.medicationadministration,
        )
      Error(error) -> Error(error)
    })
  })
}

pub fn medicationdispense_search_bundled(
  sp: search_params.Medicationdispense,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([
    #("identifier", sp.identifier),
    #("code", sp.code),
    #("performer", sp.performer),
    #("receiver", sp.receiver),
    #("subject", sp.subject),
    #("destination", sp.destination),
    #("medication", sp.medication),
    #("responsibleparty", sp.responsibleparty),
    #("encounter", sp.encounter),
    #("type", sp.type_),
    #("recorded", sp.recorded),
    #("whenhandedover", sp.whenhandedover),
    #("whenprepared", sp.whenprepared),
    #("prescription", sp.prescription),
    #("patient", sp.patient),
    #("location", sp.location),
    #("status", sp.status),
  ])
  |> search_any(resources.RtMedicationdispense, client, handle_response)
}

pub fn medicationdispense_search(
  sp: search_params.Medicationdispense,
  client: FhirClient,
  handle_response: fn(Result(List(resources.Medicationdispense), Err)) -> msg,
) -> Effect(msg) {
  medicationdispense_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) ->
        Ok({ bundle |> sansio.bundle_to_groupedresources }.medicationdispense)
      Error(error) -> Error(error)
    })
  })
}

pub fn medicationknowledge_search_bundled(
  sp: search_params.Medicationknowledge,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([
    #("product-type", sp.product_type),
    #("identifier", sp.identifier),
    #("code", sp.code),
    #("ingredient", sp.ingredient),
    #("doseform", sp.doseform),
    #("classification-type", sp.classification_type),
    #("monograph-type", sp.monograph_type),
    #("classification", sp.classification),
    #("ingredient-code", sp.ingredient_code),
    #("packaging-cost-concept", sp.packaging_cost_concept),
    #("source-cost", sp.source_cost),
    #("monitoring-program-name", sp.monitoring_program_name),
    #("monograph", sp.monograph),
    #("monitoring-program-type", sp.monitoring_program_type),
    #("packaging-cost", sp.packaging_cost),
    #("status", sp.status),
  ])
  |> search_any(resources.RtMedicationknowledge, client, handle_response)
}

pub fn medicationknowledge_search(
  sp: search_params.Medicationknowledge,
  client: FhirClient,
  handle_response: fn(Result(List(resources.Medicationknowledge), Err)) -> msg,
) -> Effect(msg) {
  medicationknowledge_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) ->
        Ok({ bundle |> sansio.bundle_to_groupedresources }.medicationknowledge)
      Error(error) -> Error(error)
    })
  })
}

pub fn medicationrequest_search_bundled(
  sp: search_params.Medicationrequest,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([
    #("requester", sp.requester),
    #("identifier", sp.identifier),
    #("intended-dispenser", sp.intended_dispenser),
    #("authoredon", sp.authoredon),
    #("code", sp.code),
    #("combo-date", sp.combo_date),
    #("subject", sp.subject),
    #("medication", sp.medication),
    #("encounter", sp.encounter),
    #("priority", sp.priority),
    #("intent", sp.intent),
    #("group-identifier", sp.group_identifier),
    #("intended-performer", sp.intended_performer),
    #("patient", sp.patient),
    #("intended-performertype", sp.intended_performertype),
    #("category", sp.category),
    #("status", sp.status),
  ])
  |> search_any(resources.RtMedicationrequest, client, handle_response)
}

pub fn medicationrequest_search(
  sp: search_params.Medicationrequest,
  client: FhirClient,
  handle_response: fn(Result(List(resources.Medicationrequest), Err)) -> msg,
) -> Effect(msg) {
  medicationrequest_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) ->
        Ok({ bundle |> sansio.bundle_to_groupedresources }.medicationrequest)
      Error(error) -> Error(error)
    })
  })
}

pub fn medicationstatement_search_bundled(
  sp: search_params.Medicationstatement,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([
    #("effective", sp.effective),
    #("identifier", sp.identifier),
    #("code", sp.code),
    #("adherence", sp.adherence),
    #("patient", sp.patient),
    #("subject", sp.subject),
    #("medication", sp.medication),
    #("encounter", sp.encounter),
    #("source", sp.source),
    #("category", sp.category),
    #("status", sp.status),
  ])
  |> search_any(resources.RtMedicationstatement, client, handle_response)
}

pub fn medicationstatement_search(
  sp: search_params.Medicationstatement,
  client: FhirClient,
  handle_response: fn(Result(List(resources.Medicationstatement), Err)) -> msg,
) -> Effect(msg) {
  medicationstatement_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) ->
        Ok({ bundle |> sansio.bundle_to_groupedresources }.medicationstatement)
      Error(error) -> Error(error)
    })
  })
}

pub fn medicinalproductdefinition_search_bundled(
  sp: search_params.Medicinalproductdefinition,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([
    #("identifier", sp.identifier),
    #("ingredient", sp.ingredient),
    #("master-file", sp.master_file),
    #("contact", sp.contact),
    #("domain", sp.domain),
    #("name", sp.name),
    #("name-language", sp.name_language),
    #("type", sp.type_),
    #("characteristic", sp.characteristic),
    #("characteristic-type", sp.characteristic_type),
    #("product-classification", sp.product_classification),
    #("status", sp.status),
  ])
  |> search_any(resources.RtMedicinalproductdefinition, client, handle_response)
}

pub fn medicinalproductdefinition_search(
  sp: search_params.Medicinalproductdefinition,
  client: FhirClient,
  handle_response: fn(Result(List(resources.Medicinalproductdefinition), Err)) ->
    msg,
) -> Effect(msg) {
  medicinalproductdefinition_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) ->
        Ok(
          { bundle |> sansio.bundle_to_groupedresources }.medicinalproductdefinition,
        )
      Error(error) -> Error(error)
    })
  })
}

pub fn messagedefinition_search_bundled(
  sp: search_params.Messagedefinition,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([
    #("date", sp.date),
    #("identifier", sp.identifier),
    #("parent", sp.parent),
    #("context-type-value", sp.context_type_value),
    #("jurisdiction", sp.jurisdiction),
    #("description", sp.description),
    #("focus", sp.focus),
    #("context-type", sp.context_type),
    #("title", sp.title),
    #("version", sp.version),
    #("url", sp.url),
    #("context-quantity", sp.context_quantity),
    #("context", sp.context),
    #("name", sp.name),
    #("publisher", sp.publisher),
    #("category", sp.category),
    #("event", sp.event),
    #("context-type-quantity", sp.context_type_quantity),
    #("status", sp.status),
  ])
  |> search_any(resources.RtMessagedefinition, client, handle_response)
}

pub fn messagedefinition_search(
  sp: search_params.Messagedefinition,
  client: FhirClient,
  handle_response: fn(Result(List(resources.Messagedefinition), Err)) -> msg,
) -> Effect(msg) {
  messagedefinition_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) ->
        Ok({ bundle |> sansio.bundle_to_groupedresources }.messagedefinition)
      Error(error) -> Error(error)
    })
  })
}

pub fn messageheader_search_bundled(
  sp: search_params.Messageheader,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([
    #("code", sp.code),
    #("receiver", sp.receiver),
    #("sender", sp.sender),
    #("author", sp.author),
    #("responsible", sp.responsible),
    #("destination", sp.destination),
    #("focus", sp.focus),
    #("response-id", sp.response_id),
    #("source", sp.source),
    #("event", sp.event),
    #("target", sp.target),
  ])
  |> search_any(resources.RtMessageheader, client, handle_response)
}

pub fn messageheader_search(
  sp: search_params.Messageheader,
  client: FhirClient,
  handle_response: fn(Result(List(resources.Messageheader), Err)) -> msg,
) -> Effect(msg) {
  messageheader_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) ->
        Ok({ bundle |> sansio.bundle_to_groupedresources }.messageheader)
      Error(error) -> Error(error)
    })
  })
}

pub fn molecularsequence_search_bundled(
  sp: search_params.Molecularsequence,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([
    #("identifier", sp.identifier),
    #("subject", sp.subject),
    #("patient", sp.patient),
    #("focus", sp.focus),
    #("type", sp.type_),
  ])
  |> search_any(resources.RtMolecularsequence, client, handle_response)
}

pub fn molecularsequence_search(
  sp: search_params.Molecularsequence,
  client: FhirClient,
  handle_response: fn(Result(List(resources.Molecularsequence), Err)) -> msg,
) -> Effect(msg) {
  molecularsequence_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) ->
        Ok({ bundle |> sansio.bundle_to_groupedresources }.molecularsequence)
      Error(error) -> Error(error)
    })
  })
}

pub fn namingsystem_search_bundled(
  sp: search_params.Namingsystem,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([
    #("date", sp.date),
    #("context-type-value", sp.context_type_value),
    #("jurisdiction", sp.jurisdiction),
    #("description", sp.description),
    #("derived-from", sp.derived_from),
    #("context-type", sp.context_type),
    #("predecessor", sp.predecessor),
    #("type", sp.type_),
    #("context-quantity", sp.context_quantity),
    #("effective", sp.effective),
    #("contact", sp.contact),
    #("responsible", sp.responsible),
    #("context", sp.context),
    #("telecom", sp.telecom),
    #("value", sp.value),
    #("context-type-quantity", sp.context_type_quantity),
    #("identifier", sp.identifier),
    #("period", sp.period),
    #("kind", sp.kind),
    #("version", sp.version),
    #("url", sp.url),
    #("id-type", sp.id_type),
    #("name", sp.name),
    #("publisher", sp.publisher),
    #("topic", sp.topic),
    #("status", sp.status),
  ])
  |> search_any(resources.RtNamingsystem, client, handle_response)
}

pub fn namingsystem_search(
  sp: search_params.Namingsystem,
  client: FhirClient,
  handle_response: fn(Result(List(resources.Namingsystem), Err)) -> msg,
) -> Effect(msg) {
  namingsystem_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) ->
        Ok({ bundle |> sansio.bundle_to_groupedresources }.namingsystem)
      Error(error) -> Error(error)
    })
  })
}

pub fn nutritionintake_search_bundled(
  sp: search_params.Nutritionintake,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([
    #("date", sp.date),
    #("identifier", sp.identifier),
    #("nutrition", sp.nutrition),
    #("code", sp.code),
    #("patient", sp.patient),
    #("subject", sp.subject),
    #("encounter", sp.encounter),
    #("source", sp.source),
    #("status", sp.status),
  ])
  |> search_any(resources.RtNutritionintake, client, handle_response)
}

pub fn nutritionintake_search(
  sp: search_params.Nutritionintake,
  client: FhirClient,
  handle_response: fn(Result(List(resources.Nutritionintake), Err)) -> msg,
) -> Effect(msg) {
  nutritionintake_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) ->
        Ok({ bundle |> sansio.bundle_to_groupedresources }.nutritionintake)
      Error(error) -> Error(error)
    })
  })
}

pub fn nutritionorder_search_bundled(
  sp: search_params.Nutritionorder,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([
    #("identifier", sp.identifier),
    #("group-identifier", sp.group_identifier),
    #("datetime", sp.datetime),
    #("provider", sp.provider),
    #("subject", sp.subject),
    #("patient", sp.patient),
    #("supplement", sp.supplement),
    #("formula", sp.formula),
    #("encounter", sp.encounter),
    #("oraldiet", sp.oraldiet),
    #("additive", sp.additive),
    #("status", sp.status),
  ])
  |> search_any(resources.RtNutritionorder, client, handle_response)
}

pub fn nutritionorder_search(
  sp: search_params.Nutritionorder,
  client: FhirClient,
  handle_response: fn(Result(List(resources.Nutritionorder), Err)) -> msg,
) -> Effect(msg) {
  nutritionorder_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) ->
        Ok({ bundle |> sansio.bundle_to_groupedresources }.nutritionorder)
      Error(error) -> Error(error)
    })
  })
}

pub fn nutritionproduct_search_bundled(
  sp: search_params.Nutritionproduct,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([
    #("identifier", sp.identifier),
    #("code", sp.code),
    #("lot-number", sp.lot_number),
    #("serial-number", sp.serial_number),
    #("status", sp.status),
  ])
  |> search_any(resources.RtNutritionproduct, client, handle_response)
}

pub fn nutritionproduct_search(
  sp: search_params.Nutritionproduct,
  client: FhirClient,
  handle_response: fn(Result(List(resources.Nutritionproduct), Err)) -> msg,
) -> Effect(msg) {
  nutritionproduct_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) ->
        Ok({ bundle |> sansio.bundle_to_groupedresources }.nutritionproduct)
      Error(error) -> Error(error)
    })
  })
}

pub fn observation_search_bundled(
  sp: search_params.Observation,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([
    #("date", sp.date),
    #("combo-data-absent-reason", sp.combo_data_absent_reason),
    #("code", sp.code),
    #("combo-code-value-quantity", sp.combo_code_value_quantity),
    #("component-data-absent-reason", sp.component_data_absent_reason),
    #("subject", sp.subject),
    #("value-concept", sp.value_concept),
    #("value-date", sp.value_date),
    #("derived-from", sp.derived_from),
    #("focus", sp.focus),
    #("part-of", sp.part_of),
    #("component-value-canonical", sp.component_value_canonical),
    #("has-member", sp.has_member),
    #("value-reference", sp.value_reference),
    #("code-value-string", sp.code_value_string),
    #("component-code-value-quantity", sp.component_code_value_quantity),
    #("based-on", sp.based_on),
    #("code-value-date", sp.code_value_date),
    #("patient", sp.patient),
    #("specimen", sp.specimen),
    #("code-value-quantity", sp.code_value_quantity),
    #("component-code", sp.component_code),
    #("value-markdown", sp.value_markdown),
    #("combo-code-value-concept", sp.combo_code_value_concept),
    #("identifier", sp.identifier),
    #("component-value-reference", sp.component_value_reference),
    #("performer", sp.performer),
    #("combo-code", sp.combo_code),
    #("method", sp.method),
    #("value-quantity", sp.value_quantity),
    #("component-value-quantity", sp.component_value_quantity),
    #("data-absent-reason", sp.data_absent_reason),
    #("combo-value-quantity", sp.combo_value_quantity),
    #("encounter", sp.encounter),
    #("code-value-concept", sp.code_value_concept),
    #("component-code-value-concept", sp.component_code_value_concept),
    #("component-value-concept", sp.component_value_concept),
    #("category", sp.category),
    #("device", sp.device),
    #("combo-value-concept", sp.combo_value_concept),
    #("value-canonical", sp.value_canonical),
    #("status", sp.status),
  ])
  |> search_any(resources.RtObservation, client, handle_response)
}

pub fn observation_search(
  sp: search_params.Observation,
  client: FhirClient,
  handle_response: fn(Result(List(resources.Observation), Err)) -> msg,
) -> Effect(msg) {
  observation_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) ->
        Ok({ bundle |> sansio.bundle_to_groupedresources }.observation)
      Error(error) -> Error(error)
    })
  })
}

pub fn observationdefinition_search_bundled(
  sp: search_params.Observationdefinition,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([
    #("identifier", sp.identifier),
    #("code", sp.code),
    #("method", sp.method),
    #("experimental", sp.experimental),
    #("category", sp.category),
    #("title", sp.title),
    #("url", sp.url),
    #("status", sp.status),
  ])
  |> search_any(resources.RtObservationdefinition, client, handle_response)
}

pub fn observationdefinition_search(
  sp: search_params.Observationdefinition,
  client: FhirClient,
  handle_response: fn(Result(List(resources.Observationdefinition), Err)) -> msg,
) -> Effect(msg) {
  observationdefinition_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) ->
        Ok(
          { bundle |> sansio.bundle_to_groupedresources }.observationdefinition,
        )
      Error(error) -> Error(error)
    })
  })
}

pub fn operationdefinition_search_bundled(
  sp: search_params.Operationdefinition,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([
    #("date", sp.date),
    #("identifier", sp.identifier),
    #("code", sp.code),
    #("instance", sp.instance),
    #("context-type-value", sp.context_type_value),
    #("kind", sp.kind),
    #("jurisdiction", sp.jurisdiction),
    #("description", sp.description),
    #("context-type", sp.context_type),
    #("title", sp.title),
    #("type", sp.type_),
    #("version", sp.version),
    #("url", sp.url),
    #("context-quantity", sp.context_quantity),
    #("input-profile", sp.input_profile),
    #("output-profile", sp.output_profile),
    #("system", sp.system),
    #("context", sp.context),
    #("name", sp.name),
    #("publisher", sp.publisher),
    #("context-type-quantity", sp.context_type_quantity),
    #("base", sp.base),
    #("status", sp.status),
  ])
  |> search_any(resources.RtOperationdefinition, client, handle_response)
}

pub fn operationdefinition_search(
  sp: search_params.Operationdefinition,
  client: FhirClient,
  handle_response: fn(Result(List(resources.Operationdefinition), Err)) -> msg,
) -> Effect(msg) {
  operationdefinition_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) ->
        Ok({ bundle |> sansio.bundle_to_groupedresources }.operationdefinition)
      Error(error) -> Error(error)
    })
  })
}

pub fn operationoutcome_search_bundled(
  _sp: search_params.Operationoutcome,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([])
  |> search_any(resources.RtOperationoutcome, client, handle_response)
}

pub fn operationoutcome_search(
  sp: search_params.Operationoutcome,
  client: FhirClient,
  handle_response: fn(Result(List(resources.Operationoutcome), Err)) -> msg,
) -> Effect(msg) {
  operationoutcome_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) ->
        Ok({ bundle |> sansio.bundle_to_groupedresources }.operationoutcome)
      Error(error) -> Error(error)
    })
  })
}

pub fn organization_search_bundled(
  sp: search_params.Organization,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([
    #("identifier", sp.identifier),
    #("partof", sp.partof),
    #("address", sp.address),
    #("address-state", sp.address_state),
    #("active", sp.active),
    #("type", sp.type_),
    #("address-postalcode", sp.address_postalcode),
    #("address-country", sp.address_country),
    #("endpoint", sp.endpoint),
    #("phonetic", sp.phonetic),
    #("address-use", sp.address_use),
    #("name", sp.name),
    #("address-city", sp.address_city),
  ])
  |> search_any(resources.RtOrganization, client, handle_response)
}

pub fn organization_search(
  sp: search_params.Organization,
  client: FhirClient,
  handle_response: fn(Result(List(resources.Organization), Err)) -> msg,
) -> Effect(msg) {
  organization_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) ->
        Ok({ bundle |> sansio.bundle_to_groupedresources }.organization)
      Error(error) -> Error(error)
    })
  })
}

pub fn organizationaffiliation_search_bundled(
  sp: search_params.Organizationaffiliation,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([
    #("date", sp.date),
    #("identifier", sp.identifier),
    #("specialty", sp.specialty),
    #("role", sp.role),
    #("active", sp.active),
    #("primary-organization", sp.primary_organization),
    #("network", sp.network),
    #("endpoint", sp.endpoint),
    #("phone", sp.phone),
    #("service", sp.service),
    #("participating-organization", sp.participating_organization),
    #("location", sp.location),
    #("telecom", sp.telecom),
    #("email", sp.email),
  ])
  |> search_any(resources.RtOrganizationaffiliation, client, handle_response)
}

pub fn organizationaffiliation_search(
  sp: search_params.Organizationaffiliation,
  client: FhirClient,
  handle_response: fn(Result(List(resources.Organizationaffiliation), Err)) ->
    msg,
) -> Effect(msg) {
  organizationaffiliation_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) ->
        Ok(
          { bundle |> sansio.bundle_to_groupedresources }.organizationaffiliation,
        )
      Error(error) -> Error(error)
    })
  })
}

pub fn packagedproductdefinition_search_bundled(
  sp: search_params.Packagedproductdefinition,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([
    #("identifier", sp.identifier),
    #("manufactured-item", sp.manufactured_item),
    #("nutrition", sp.nutrition),
    #("package", sp.package),
    #("name", sp.name),
    #("biological", sp.biological),
    #("package-for", sp.package_for),
    #("contained-item", sp.contained_item),
    #("medication", sp.medication),
    #("device", sp.device),
    #("status", sp.status),
  ])
  |> search_any(resources.RtPackagedproductdefinition, client, handle_response)
}

pub fn packagedproductdefinition_search(
  sp: search_params.Packagedproductdefinition,
  client: FhirClient,
  handle_response: fn(Result(List(resources.Packagedproductdefinition), Err)) ->
    msg,
) -> Effect(msg) {
  packagedproductdefinition_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) ->
        Ok(
          { bundle |> sansio.bundle_to_groupedresources }.packagedproductdefinition,
        )
      Error(error) -> Error(error)
    })
  })
}

pub fn patient_search_bundled(
  sp: search_params.Patient,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([
    #("given", sp.given),
    #("identifier", sp.identifier),
    #("address", sp.address),
    #("birthdate", sp.birthdate),
    #("deceased", sp.deceased),
    #("address-state", sp.address_state),
    #("gender", sp.gender),
    #("general-practitioner", sp.general_practitioner),
    #("link", sp.link),
    #("active", sp.active),
    #("language", sp.language),
    #("address-postalcode", sp.address_postalcode),
    #("address-country", sp.address_country),
    #("death-date", sp.death_date),
    #("phonetic", sp.phonetic),
    #("phone", sp.phone),
    #("organization", sp.organization),
    #("address-use", sp.address_use),
    #("name", sp.name),
    #("telecom", sp.telecom),
    #("address-city", sp.address_city),
    #("family", sp.family),
    #("email", sp.email),
  ])
  |> search_any(resources.RtPatient, client, handle_response)
}

pub fn patient_search(
  sp: search_params.Patient,
  client: FhirClient,
  handle_response: fn(Result(List(resources.Patient), Err)) -> msg,
) -> Effect(msg) {
  patient_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) -> Ok({ bundle |> sansio.bundle_to_groupedresources }.patient)
      Error(error) -> Error(error)
    })
  })
}

pub fn paymentnotice_search_bundled(
  sp: search_params.Paymentnotice,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([
    #("identifier", sp.identifier),
    #("request", sp.request),
    #("created", sp.created),
    #("response", sp.response),
    #("reporter", sp.reporter),
    #("payment-status", sp.payment_status),
    #("status", sp.status),
  ])
  |> search_any(resources.RtPaymentnotice, client, handle_response)
}

pub fn paymentnotice_search(
  sp: search_params.Paymentnotice,
  client: FhirClient,
  handle_response: fn(Result(List(resources.Paymentnotice), Err)) -> msg,
) -> Effect(msg) {
  paymentnotice_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) ->
        Ok({ bundle |> sansio.bundle_to_groupedresources }.paymentnotice)
      Error(error) -> Error(error)
    })
  })
}

pub fn paymentreconciliation_search_bundled(
  sp: search_params.Paymentreconciliation,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([
    #("identifier", sp.identifier),
    #("request", sp.request),
    #("disposition", sp.disposition),
    #("created", sp.created),
    #("allocation-encounter", sp.allocation_encounter),
    #("allocation-account", sp.allocation_account),
    #("outcome", sp.outcome),
    #("payment-issuer", sp.payment_issuer),
    #("requestor", sp.requestor),
    #("status", sp.status),
  ])
  |> search_any(resources.RtPaymentreconciliation, client, handle_response)
}

pub fn paymentreconciliation_search(
  sp: search_params.Paymentreconciliation,
  client: FhirClient,
  handle_response: fn(Result(List(resources.Paymentreconciliation), Err)) -> msg,
) -> Effect(msg) {
  paymentreconciliation_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) ->
        Ok(
          { bundle |> sansio.bundle_to_groupedresources }.paymentreconciliation,
        )
      Error(error) -> Error(error)
    })
  })
}

pub fn permission_search_bundled(
  sp: search_params.Permission,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([
    #("status", sp.status),
  ])
  |> search_any(resources.RtPermission, client, handle_response)
}

pub fn permission_search(
  sp: search_params.Permission,
  client: FhirClient,
  handle_response: fn(Result(List(resources.Permission), Err)) -> msg,
) -> Effect(msg) {
  permission_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) ->
        Ok({ bundle |> sansio.bundle_to_groupedresources }.permission)
      Error(error) -> Error(error)
    })
  })
}

pub fn person_search_bundled(
  sp: search_params.Person,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([
    #("identifier", sp.identifier),
    #("given", sp.given),
    #("address", sp.address),
    #("birthdate", sp.birthdate),
    #("deceased", sp.deceased),
    #("address-state", sp.address_state),
    #("gender", sp.gender),
    #("practitioner", sp.practitioner),
    #("link", sp.link),
    #("relatedperson", sp.relatedperson),
    #("address-postalcode", sp.address_postalcode),
    #("address-country", sp.address_country),
    #("death-date", sp.death_date),
    #("phonetic", sp.phonetic),
    #("phone", sp.phone),
    #("patient", sp.patient),
    #("organization", sp.organization),
    #("address-use", sp.address_use),
    #("name", sp.name),
    #("telecom", sp.telecom),
    #("address-city", sp.address_city),
    #("family", sp.family),
    #("email", sp.email),
  ])
  |> search_any(resources.RtPerson, client, handle_response)
}

pub fn person_search(
  sp: search_params.Person,
  client: FhirClient,
  handle_response: fn(Result(List(resources.Person), Err)) -> msg,
) -> Effect(msg) {
  person_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) -> Ok({ bundle |> sansio.bundle_to_groupedresources }.person)
      Error(error) -> Error(error)
    })
  })
}

pub fn plandefinition_search_bundled(
  sp: search_params.Plandefinition,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([
    #("date", sp.date),
    #("identifier", sp.identifier),
    #("successor", sp.successor),
    #("context-type-value", sp.context_type_value),
    #("jurisdiction", sp.jurisdiction),
    #("derived-from", sp.derived_from),
    #("description", sp.description),
    #("context-type", sp.context_type),
    #("predecessor", sp.predecessor),
    #("composed-of", sp.composed_of),
    #("title", sp.title),
    #("type", sp.type_),
    #("version", sp.version),
    #("url", sp.url),
    #("context-quantity", sp.context_quantity),
    #("depends-on", sp.depends_on),
    #("effective", sp.effective),
    #("context", sp.context),
    #("name", sp.name),
    #("publisher", sp.publisher),
    #("topic", sp.topic),
    #("definition", sp.definition),
    #("context-type-quantity", sp.context_type_quantity),
    #("status", sp.status),
  ])
  |> search_any(resources.RtPlandefinition, client, handle_response)
}

pub fn plandefinition_search(
  sp: search_params.Plandefinition,
  client: FhirClient,
  handle_response: fn(Result(List(resources.Plandefinition), Err)) -> msg,
) -> Effect(msg) {
  plandefinition_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) ->
        Ok({ bundle |> sansio.bundle_to_groupedresources }.plandefinition)
      Error(error) -> Error(error)
    })
  })
}

pub fn practitioner_search_bundled(
  sp: search_params.Practitioner,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([
    #("given", sp.given),
    #("identifier", sp.identifier),
    #("address", sp.address),
    #("deceased", sp.deceased),
    #("address-state", sp.address_state),
    #("gender", sp.gender),
    #("qualification-period", sp.qualification_period),
    #("active", sp.active),
    #("address-postalcode", sp.address_postalcode),
    #("address-country", sp.address_country),
    #("death-date", sp.death_date),
    #("phonetic", sp.phonetic),
    #("phone", sp.phone),
    #("address-use", sp.address_use),
    #("name", sp.name),
    #("telecom", sp.telecom),
    #("address-city", sp.address_city),
    #("communication", sp.communication),
    #("family", sp.family),
    #("email", sp.email),
  ])
  |> search_any(resources.RtPractitioner, client, handle_response)
}

pub fn practitioner_search(
  sp: search_params.Practitioner,
  client: FhirClient,
  handle_response: fn(Result(List(resources.Practitioner), Err)) -> msg,
) -> Effect(msg) {
  practitioner_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) ->
        Ok({ bundle |> sansio.bundle_to_groupedresources }.practitioner)
      Error(error) -> Error(error)
    })
  })
}

pub fn practitionerrole_search_bundled(
  sp: search_params.Practitionerrole,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([
    #("date", sp.date),
    #("identifier", sp.identifier),
    #("specialty", sp.specialty),
    #("role", sp.role),
    #("practitioner", sp.practitioner),
    #("active", sp.active),
    #("characteristic", sp.characteristic),
    #("endpoint", sp.endpoint),
    #("phone", sp.phone),
    #("service", sp.service),
    #("organization", sp.organization),
    #("location", sp.location),
    #("telecom", sp.telecom),
    #("communication", sp.communication),
    #("email", sp.email),
  ])
  |> search_any(resources.RtPractitionerrole, client, handle_response)
}

pub fn practitionerrole_search(
  sp: search_params.Practitionerrole,
  client: FhirClient,
  handle_response: fn(Result(List(resources.Practitionerrole), Err)) -> msg,
) -> Effect(msg) {
  practitionerrole_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) ->
        Ok({ bundle |> sansio.bundle_to_groupedresources }.practitionerrole)
      Error(error) -> Error(error)
    })
  })
}

pub fn procedure_search_bundled(
  sp: search_params.Procedure,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([
    #("date", sp.date),
    #("identifier", sp.identifier),
    #("code", sp.code),
    #("performer", sp.performer),
    #("subject", sp.subject),
    #("instantiates-canonical", sp.instantiates_canonical),
    #("part-of", sp.part_of),
    #("encounter", sp.encounter),
    #("reason-code", sp.reason_code),
    #("based-on", sp.based_on),
    #("patient", sp.patient),
    #("reason-reference", sp.reason_reference),
    #("report", sp.report),
    #("instantiates-uri", sp.instantiates_uri),
    #("location", sp.location),
    #("category", sp.category),
    #("status", sp.status),
  ])
  |> search_any(resources.RtProcedure, client, handle_response)
}

pub fn procedure_search(
  sp: search_params.Procedure,
  client: FhirClient,
  handle_response: fn(Result(List(resources.Procedure), Err)) -> msg,
) -> Effect(msg) {
  procedure_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) ->
        Ok({ bundle |> sansio.bundle_to_groupedresources }.procedure)
      Error(error) -> Error(error)
    })
  })
}

pub fn provenance_search_bundled(
  sp: search_params.Provenance,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([
    #("agent-type", sp.agent_type),
    #("agent", sp.agent),
    #("signature-type", sp.signature_type),
    #("activity", sp.activity),
    #("encounter", sp.encounter),
    #("recorded", sp.recorded),
    #("when", sp.when),
    #("target", sp.target),
    #("based-on", sp.based_on),
    #("patient", sp.patient),
    #("location", sp.location),
    #("agent-role", sp.agent_role),
    #("entity", sp.entity),
  ])
  |> search_any(resources.RtProvenance, client, handle_response)
}

pub fn provenance_search(
  sp: search_params.Provenance,
  client: FhirClient,
  handle_response: fn(Result(List(resources.Provenance), Err)) -> msg,
) -> Effect(msg) {
  provenance_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) ->
        Ok({ bundle |> sansio.bundle_to_groupedresources }.provenance)
      Error(error) -> Error(error)
    })
  })
}

pub fn questionnaire_search_bundled(
  sp: search_params.Questionnaire,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([
    #("date", sp.date),
    #("identifier", sp.identifier),
    #("combo-code", sp.combo_code),
    #("context-type-value", sp.context_type_value),
    #("jurisdiction", sp.jurisdiction),
    #("description", sp.description),
    #("context-type", sp.context_type),
    #("title", sp.title),
    #("version", sp.version),
    #("url", sp.url),
    #("context-quantity", sp.context_quantity),
    #("effective", sp.effective),
    #("subject-type", sp.subject_type),
    #("context", sp.context),
    #("name", sp.name),
    #("publisher", sp.publisher),
    #("questionnaire-code", sp.questionnaire_code),
    #("definition", sp.definition),
    #("context-type-quantity", sp.context_type_quantity),
    #("item-code", sp.item_code),
    #("status", sp.status),
  ])
  |> search_any(resources.RtQuestionnaire, client, handle_response)
}

pub fn questionnaire_search(
  sp: search_params.Questionnaire,
  client: FhirClient,
  handle_response: fn(Result(List(resources.Questionnaire), Err)) -> msg,
) -> Effect(msg) {
  questionnaire_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) ->
        Ok({ bundle |> sansio.bundle_to_groupedresources }.questionnaire)
      Error(error) -> Error(error)
    })
  })
}

pub fn questionnaireresponse_search_bundled(
  sp: search_params.Questionnaireresponse,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([
    #("authored", sp.authored),
    #("identifier", sp.identifier),
    #("questionnaire", sp.questionnaire),
    #("based-on", sp.based_on),
    #("author", sp.author),
    #("patient", sp.patient),
    #("subject", sp.subject),
    #("part-of", sp.part_of),
    #("encounter", sp.encounter),
    #("source", sp.source),
    #("item-subject", sp.item_subject),
    #("status", sp.status),
  ])
  |> search_any(resources.RtQuestionnaireresponse, client, handle_response)
}

pub fn questionnaireresponse_search(
  sp: search_params.Questionnaireresponse,
  client: FhirClient,
  handle_response: fn(Result(List(resources.Questionnaireresponse), Err)) -> msg,
) -> Effect(msg) {
  questionnaireresponse_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) ->
        Ok(
          { bundle |> sansio.bundle_to_groupedresources }.questionnaireresponse,
        )
      Error(error) -> Error(error)
    })
  })
}

pub fn regulatedauthorization_search_bundled(
  sp: search_params.Regulatedauthorization,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([
    #("identifier", sp.identifier),
    #("subject", sp.subject),
    #("case-type", sp.case_type),
    #("holder", sp.holder),
    #("region", sp.region),
    #("case", sp.case_),
    #("status", sp.status),
  ])
  |> search_any(resources.RtRegulatedauthorization, client, handle_response)
}

pub fn regulatedauthorization_search(
  sp: search_params.Regulatedauthorization,
  client: FhirClient,
  handle_response: fn(Result(List(resources.Regulatedauthorization), Err)) ->
    msg,
) -> Effect(msg) {
  regulatedauthorization_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) ->
        Ok(
          { bundle |> sansio.bundle_to_groupedresources }.regulatedauthorization,
        )
      Error(error) -> Error(error)
    })
  })
}

pub fn relatedperson_search_bundled(
  sp: search_params.Relatedperson,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([
    #("identifier", sp.identifier),
    #("given", sp.given),
    #("address", sp.address),
    #("birthdate", sp.birthdate),
    #("address-state", sp.address_state),
    #("gender", sp.gender),
    #("active", sp.active),
    #("address-postalcode", sp.address_postalcode),
    #("address-country", sp.address_country),
    #("phonetic", sp.phonetic),
    #("phone", sp.phone),
    #("patient", sp.patient),
    #("address-use", sp.address_use),
    #("name", sp.name),
    #("telecom", sp.telecom),
    #("address-city", sp.address_city),
    #("family", sp.family),
    #("relationship", sp.relationship),
    #("email", sp.email),
  ])
  |> search_any(resources.RtRelatedperson, client, handle_response)
}

pub fn relatedperson_search(
  sp: search_params.Relatedperson,
  client: FhirClient,
  handle_response: fn(Result(List(resources.Relatedperson), Err)) -> msg,
) -> Effect(msg) {
  relatedperson_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) ->
        Ok({ bundle |> sansio.bundle_to_groupedresources }.relatedperson)
      Error(error) -> Error(error)
    })
  })
}

pub fn requestorchestration_search_bundled(
  sp: search_params.Requestorchestration,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([
    #("authored", sp.authored),
    #("identifier", sp.identifier),
    #("code", sp.code),
    #("author", sp.author),
    #("subject", sp.subject),
    #("instantiates-canonical", sp.instantiates_canonical),
    #("encounter", sp.encounter),
    #("priority", sp.priority),
    #("intent", sp.intent),
    #("participant", sp.participant),
    #("group-identifier", sp.group_identifier),
    #("based-on", sp.based_on),
    #("patient", sp.patient),
    #("instantiates-uri", sp.instantiates_uri),
    #("status", sp.status),
  ])
  |> search_any(resources.RtRequestorchestration, client, handle_response)
}

pub fn requestorchestration_search(
  sp: search_params.Requestorchestration,
  client: FhirClient,
  handle_response: fn(Result(List(resources.Requestorchestration), Err)) -> msg,
) -> Effect(msg) {
  requestorchestration_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) ->
        Ok({ bundle |> sansio.bundle_to_groupedresources }.requestorchestration)
      Error(error) -> Error(error)
    })
  })
}

pub fn requirements_search_bundled(
  sp: search_params.Requirements,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([
    #("date", sp.date),
    #("identifier", sp.identifier),
    #("context-type-value", sp.context_type_value),
    #("jurisdiction", sp.jurisdiction),
    #("description", sp.description),
    #("derived-from", sp.derived_from),
    #("context-type", sp.context_type),
    #("title", sp.title),
    #("version", sp.version),
    #("url", sp.url),
    #("actor", sp.actor),
    #("context-quantity", sp.context_quantity),
    #("context", sp.context),
    #("name", sp.name),
    #("publisher", sp.publisher),
    #("context-type-quantity", sp.context_type_quantity),
    #("status", sp.status),
  ])
  |> search_any(resources.RtRequirements, client, handle_response)
}

pub fn requirements_search(
  sp: search_params.Requirements,
  client: FhirClient,
  handle_response: fn(Result(List(resources.Requirements), Err)) -> msg,
) -> Effect(msg) {
  requirements_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) ->
        Ok({ bundle |> sansio.bundle_to_groupedresources }.requirements)
      Error(error) -> Error(error)
    })
  })
}

pub fn researchstudy_search_bundled(
  sp: search_params.Researchstudy,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([
    #("date", sp.date),
    #("objective-type", sp.objective_type),
    #("study-design", sp.study_design),
    #("description", sp.description),
    #("eligibility", sp.eligibility),
    #("part-of", sp.part_of),
    #("title", sp.title),
    #(
      "progress-status-state-period-actual",
      sp.progress_status_state_period_actual,
    ),
    #("recruitment-target", sp.recruitment_target),
    #("protocol", sp.protocol),
    #("classifier", sp.classifier),
    #("keyword", sp.keyword),
    #("focus-code", sp.focus_code),
    #("phase", sp.phase),
    #("identifier", sp.identifier),
    #("progress-status-state-actual", sp.progress_status_state_actual),
    #("focus-reference", sp.focus_reference),
    #("objective-description", sp.objective_description),
    #("progress-status-state-period", sp.progress_status_state_period),
    #("condition", sp.condition),
    #("site", sp.site),
    #("name", sp.name),
    #("recruitment-actual", sp.recruitment_actual),
    #("region", sp.region),
    #("status", sp.status),
  ])
  |> search_any(resources.RtResearchstudy, client, handle_response)
}

pub fn researchstudy_search(
  sp: search_params.Researchstudy,
  client: FhirClient,
  handle_response: fn(Result(List(resources.Researchstudy), Err)) -> msg,
) -> Effect(msg) {
  researchstudy_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) ->
        Ok({ bundle |> sansio.bundle_to_groupedresources }.researchstudy)
      Error(error) -> Error(error)
    })
  })
}

pub fn researchsubject_search_bundled(
  sp: search_params.Researchsubject,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([
    #("date", sp.date),
    #("identifier", sp.identifier),
    #("subject_state", sp.subject_state),
    #("study", sp.study),
    #("subject", sp.subject),
    #("patient", sp.patient),
    #("status", sp.status),
  ])
  |> search_any(resources.RtResearchsubject, client, handle_response)
}

pub fn researchsubject_search(
  sp: search_params.Researchsubject,
  client: FhirClient,
  handle_response: fn(Result(List(resources.Researchsubject), Err)) -> msg,
) -> Effect(msg) {
  researchsubject_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) ->
        Ok({ bundle |> sansio.bundle_to_groupedresources }.researchsubject)
      Error(error) -> Error(error)
    })
  })
}

pub fn riskassessment_search_bundled(
  sp: search_params.Riskassessment,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([
    #("date", sp.date),
    #("identifier", sp.identifier),
    #("condition", sp.condition),
    #("performer", sp.performer),
    #("method", sp.method),
    #("patient", sp.patient),
    #("probability", sp.probability),
    #("subject", sp.subject),
    #("risk", sp.risk),
    #("encounter", sp.encounter),
  ])
  |> search_any(resources.RtRiskassessment, client, handle_response)
}

pub fn riskassessment_search(
  sp: search_params.Riskassessment,
  client: FhirClient,
  handle_response: fn(Result(List(resources.Riskassessment), Err)) -> msg,
) -> Effect(msg) {
  riskassessment_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) ->
        Ok({ bundle |> sansio.bundle_to_groupedresources }.riskassessment)
      Error(error) -> Error(error)
    })
  })
}

pub fn schedule_search_bundled(
  sp: search_params.Schedule,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([
    #("actor", sp.actor),
    #("date", sp.date),
    #("identifier", sp.identifier),
    #("specialty", sp.specialty),
    #("service-category", sp.service_category),
    #("service-type", sp.service_type),
    #("name", sp.name),
    #("active", sp.active),
    #("service-type-reference", sp.service_type_reference),
  ])
  |> search_any(resources.RtSchedule, client, handle_response)
}

pub fn schedule_search(
  sp: search_params.Schedule,
  client: FhirClient,
  handle_response: fn(Result(List(resources.Schedule), Err)) -> msg,
) -> Effect(msg) {
  schedule_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) -> Ok({ bundle |> sansio.bundle_to_groupedresources }.schedule)
      Error(error) -> Error(error)
    })
  })
}

pub fn searchparameter_search_bundled(
  sp: search_params.Searchparameter,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([
    #("date", sp.date),
    #("identifier", sp.identifier),
    #("code", sp.code),
    #("context-type-value", sp.context_type_value),
    #("jurisdiction", sp.jurisdiction),
    #("derived-from", sp.derived_from),
    #("description", sp.description),
    #("context-type", sp.context_type),
    #("type", sp.type_),
    #("version", sp.version),
    #("url", sp.url),
    #("target", sp.target),
    #("context-quantity", sp.context_quantity),
    #("component", sp.component),
    #("context", sp.context),
    #("name", sp.name),
    #("publisher", sp.publisher),
    #("context-type-quantity", sp.context_type_quantity),
    #("base", sp.base),
    #("status", sp.status),
  ])
  |> search_any(resources.RtSearchparameter, client, handle_response)
}

pub fn searchparameter_search(
  sp: search_params.Searchparameter,
  client: FhirClient,
  handle_response: fn(Result(List(resources.Searchparameter), Err)) -> msg,
) -> Effect(msg) {
  searchparameter_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) ->
        Ok({ bundle |> sansio.bundle_to_groupedresources }.searchparameter)
      Error(error) -> Error(error)
    })
  })
}

pub fn servicerequest_search_bundled(
  sp: search_params.Servicerequest,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([
    #("authored", sp.authored),
    #("requester", sp.requester),
    #("identifier", sp.identifier),
    #("performer", sp.performer),
    #("requisition", sp.requisition),
    #("replaces", sp.replaces),
    #("subject", sp.subject),
    #("instantiates-canonical", sp.instantiates_canonical),
    #("encounter", sp.encounter),
    #("occurrence", sp.occurrence),
    #("priority", sp.priority),
    #("intent", sp.intent),
    #("performer-type", sp.performer_type),
    #("body-structure", sp.body_structure),
    #("based-on", sp.based_on),
    #("code-reference", sp.code_reference),
    #("patient", sp.patient),
    #("specimen", sp.specimen),
    #("code-concept", sp.code_concept),
    #("instantiates-uri", sp.instantiates_uri),
    #("body-site", sp.body_site),
    #("category", sp.category),
    #("status", sp.status),
  ])
  |> search_any(resources.RtServicerequest, client, handle_response)
}

pub fn servicerequest_search(
  sp: search_params.Servicerequest,
  client: FhirClient,
  handle_response: fn(Result(List(resources.Servicerequest), Err)) -> msg,
) -> Effect(msg) {
  servicerequest_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) ->
        Ok({ bundle |> sansio.bundle_to_groupedresources }.servicerequest)
      Error(error) -> Error(error)
    })
  })
}

pub fn slot_search_bundled(
  sp: search_params.Slot,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([
    #("identifier", sp.identifier),
    #("schedule", sp.schedule),
    #("specialty", sp.specialty),
    #("service-category", sp.service_category),
    #("appointment-type", sp.appointment_type),
    #("service-type", sp.service_type),
    #("start", sp.start),
    #("service-type-reference", sp.service_type_reference),
    #("status", sp.status),
  ])
  |> search_any(resources.RtSlot, client, handle_response)
}

pub fn slot_search(
  sp: search_params.Slot,
  client: FhirClient,
  handle_response: fn(Result(List(resources.Slot), Err)) -> msg,
) -> Effect(msg) {
  slot_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) -> Ok({ bundle |> sansio.bundle_to_groupedresources }.slot)
      Error(error) -> Error(error)
    })
  })
}

pub fn specimen_search_bundled(
  sp: search_params.Specimen,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([
    #("identifier", sp.identifier),
    #("parent", sp.parent),
    #("bodysite", sp.bodysite),
    #("patient", sp.patient),
    #("subject", sp.subject),
    #("collected", sp.collected),
    #("accession", sp.accession),
    #("procedure", sp.procedure),
    #("type", sp.type_),
    #("collector", sp.collector),
    #("container-device", sp.container_device),
    #("status", sp.status),
  ])
  |> search_any(resources.RtSpecimen, client, handle_response)
}

pub fn specimen_search(
  sp: search_params.Specimen,
  client: FhirClient,
  handle_response: fn(Result(List(resources.Specimen), Err)) -> msg,
) -> Effect(msg) {
  specimen_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) -> Ok({ bundle |> sansio.bundle_to_groupedresources }.specimen)
      Error(error) -> Error(error)
    })
  })
}

pub fn specimendefinition_search_bundled(
  sp: search_params.Specimendefinition,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([
    #("container", sp.container),
    #("identifier", sp.identifier),
    #("is-derived", sp.is_derived),
    #("experimental", sp.experimental),
    #("type-tested", sp.type_tested),
    #("title", sp.title),
    #("type", sp.type_),
    #("url", sp.url),
    #("status", sp.status),
  ])
  |> search_any(resources.RtSpecimendefinition, client, handle_response)
}

pub fn specimendefinition_search(
  sp: search_params.Specimendefinition,
  client: FhirClient,
  handle_response: fn(Result(List(resources.Specimendefinition), Err)) -> msg,
) -> Effect(msg) {
  specimendefinition_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) ->
        Ok({ bundle |> sansio.bundle_to_groupedresources }.specimendefinition)
      Error(error) -> Error(error)
    })
  })
}

pub fn structuredefinition_search_bundled(
  sp: search_params.Structuredefinition,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([
    #("date", sp.date),
    #("context-type-value", sp.context_type_value),
    #("ext-context-type", sp.ext_context_type),
    #("jurisdiction", sp.jurisdiction),
    #("description", sp.description),
    #("context-type", sp.context_type),
    #("experimental", sp.experimental),
    #("title", sp.title),
    #("type", sp.type_),
    #("context-quantity", sp.context_quantity),
    #("path", sp.path),
    #("base-path", sp.base_path),
    #("context", sp.context),
    #("keyword", sp.keyword),
    #("context-type-quantity", sp.context_type_quantity),
    #("ext-context-expression", sp.ext_context_expression),
    #("identifier", sp.identifier),
    #("valueset", sp.valueset),
    #("kind", sp.kind),
    #("abstract", sp.abstract),
    #("version", sp.version),
    #("url", sp.url),
    #("ext-context", sp.ext_context),
    #("name", sp.name),
    #("publisher", sp.publisher),
    #("derivation", sp.derivation),
    #("base", sp.base),
    #("status", sp.status),
  ])
  |> search_any(resources.RtStructuredefinition, client, handle_response)
}

pub fn structuredefinition_search(
  sp: search_params.Structuredefinition,
  client: FhirClient,
  handle_response: fn(Result(List(resources.Structuredefinition), Err)) -> msg,
) -> Effect(msg) {
  structuredefinition_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) ->
        Ok({ bundle |> sansio.bundle_to_groupedresources }.structuredefinition)
      Error(error) -> Error(error)
    })
  })
}

pub fn structuremap_search_bundled(
  sp: search_params.Structuremap,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([
    #("date", sp.date),
    #("identifier", sp.identifier),
    #("context-type-value", sp.context_type_value),
    #("jurisdiction", sp.jurisdiction),
    #("description", sp.description),
    #("context-type", sp.context_type),
    #("title", sp.title),
    #("version", sp.version),
    #("url", sp.url),
    #("context-quantity", sp.context_quantity),
    #("context", sp.context),
    #("name", sp.name),
    #("publisher", sp.publisher),
    #("context-type-quantity", sp.context_type_quantity),
    #("status", sp.status),
  ])
  |> search_any(resources.RtStructuremap, client, handle_response)
}

pub fn structuremap_search(
  sp: search_params.Structuremap,
  client: FhirClient,
  handle_response: fn(Result(List(resources.Structuremap), Err)) -> msg,
) -> Effect(msg) {
  structuremap_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) ->
        Ok({ bundle |> sansio.bundle_to_groupedresources }.structuremap)
      Error(error) -> Error(error)
    })
  })
}

pub fn subscription_search_bundled(
  sp: search_params.Subscription,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([
    #("owner", sp.owner),
    #("identifier", sp.identifier),
    #("payload", sp.payload),
    #("contact", sp.contact),
    #("name", sp.name),
    #("topic", sp.topic),
    #("filter-value", sp.filter_value),
    #("type", sp.type_),
    #("content-level", sp.content_level),
    #("url", sp.url),
    #("status", sp.status),
  ])
  |> search_any(resources.RtSubscription, client, handle_response)
}

pub fn subscription_search(
  sp: search_params.Subscription,
  client: FhirClient,
  handle_response: fn(Result(List(resources.Subscription), Err)) -> msg,
) -> Effect(msg) {
  subscription_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) ->
        Ok({ bundle |> sansio.bundle_to_groupedresources }.subscription)
      Error(error) -> Error(error)
    })
  })
}

pub fn subscriptionstatus_search_bundled(
  _sp: search_params.Subscriptionstatus,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([])
  |> search_any(resources.RtSubscriptionstatus, client, handle_response)
}

pub fn subscriptionstatus_search(
  sp: search_params.Subscriptionstatus,
  client: FhirClient,
  handle_response: fn(Result(List(resources.Subscriptionstatus), Err)) -> msg,
) -> Effect(msg) {
  subscriptionstatus_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) ->
        Ok({ bundle |> sansio.bundle_to_groupedresources }.subscriptionstatus)
      Error(error) -> Error(error)
    })
  })
}

pub fn subscriptiontopic_search_bundled(
  sp: search_params.Subscriptiontopic,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([
    #("date", sp.date),
    #("effective", sp.effective),
    #("identifier", sp.identifier),
    #("resource", sp.resource),
    #("derived-or-self", sp.derived_or_self),
    #("event", sp.event),
    #("title", sp.title),
    #("version", sp.version),
    #("url", sp.url),
    #("status", sp.status),
    #("trigger-description", sp.trigger_description),
  ])
  |> search_any(resources.RtSubscriptiontopic, client, handle_response)
}

pub fn subscriptiontopic_search(
  sp: search_params.Subscriptiontopic,
  client: FhirClient,
  handle_response: fn(Result(List(resources.Subscriptiontopic), Err)) -> msg,
) -> Effect(msg) {
  subscriptiontopic_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) ->
        Ok({ bundle |> sansio.bundle_to_groupedresources }.subscriptiontopic)
      Error(error) -> Error(error)
    })
  })
}

pub fn substance_search_bundled(
  sp: search_params.Substance,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([
    #("identifier", sp.identifier),
    #("code", sp.code),
    #("code-reference", sp.code_reference),
    #("quantity", sp.quantity),
    #("substance-reference", sp.substance_reference),
    #("expiry", sp.expiry),
    #("category", sp.category),
    #("status", sp.status),
  ])
  |> search_any(resources.RtSubstance, client, handle_response)
}

pub fn substance_search(
  sp: search_params.Substance,
  client: FhirClient,
  handle_response: fn(Result(List(resources.Substance), Err)) -> msg,
) -> Effect(msg) {
  substance_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) ->
        Ok({ bundle |> sansio.bundle_to_groupedresources }.substance)
      Error(error) -> Error(error)
    })
  })
}

pub fn substancedefinition_search_bundled(
  sp: search_params.Substancedefinition,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([
    #("identifier", sp.identifier),
    #("code", sp.code),
    #("domain", sp.domain),
    #("name", sp.name),
    #("classification", sp.classification),
  ])
  |> search_any(resources.RtSubstancedefinition, client, handle_response)
}

pub fn substancedefinition_search(
  sp: search_params.Substancedefinition,
  client: FhirClient,
  handle_response: fn(Result(List(resources.Substancedefinition), Err)) -> msg,
) -> Effect(msg) {
  substancedefinition_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) ->
        Ok({ bundle |> sansio.bundle_to_groupedresources }.substancedefinition)
      Error(error) -> Error(error)
    })
  })
}

pub fn substancenucleicacid_search_bundled(
  _sp: search_params.Substancenucleicacid,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([])
  |> search_any(resources.RtSubstancenucleicacid, client, handle_response)
}

pub fn substancenucleicacid_search(
  sp: search_params.Substancenucleicacid,
  client: FhirClient,
  handle_response: fn(Result(List(resources.Substancenucleicacid), Err)) -> msg,
) -> Effect(msg) {
  substancenucleicacid_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) ->
        Ok({ bundle |> sansio.bundle_to_groupedresources }.substancenucleicacid)
      Error(error) -> Error(error)
    })
  })
}

pub fn substancepolymer_search_bundled(
  _sp: search_params.Substancepolymer,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([])
  |> search_any(resources.RtSubstancepolymer, client, handle_response)
}

pub fn substancepolymer_search(
  sp: search_params.Substancepolymer,
  client: FhirClient,
  handle_response: fn(Result(List(resources.Substancepolymer), Err)) -> msg,
) -> Effect(msg) {
  substancepolymer_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) ->
        Ok({ bundle |> sansio.bundle_to_groupedresources }.substancepolymer)
      Error(error) -> Error(error)
    })
  })
}

pub fn substanceprotein_search_bundled(
  _sp: search_params.Substanceprotein,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([])
  |> search_any(resources.RtSubstanceprotein, client, handle_response)
}

pub fn substanceprotein_search(
  sp: search_params.Substanceprotein,
  client: FhirClient,
  handle_response: fn(Result(List(resources.Substanceprotein), Err)) -> msg,
) -> Effect(msg) {
  substanceprotein_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) ->
        Ok({ bundle |> sansio.bundle_to_groupedresources }.substanceprotein)
      Error(error) -> Error(error)
    })
  })
}

pub fn substancereferenceinformation_search_bundled(
  _sp: search_params.Substancereferenceinformation,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([])
  |> search_any(
    resources.RtSubstancereferenceinformation,
    client,
    handle_response,
  )
}

pub fn substancereferenceinformation_search(
  sp: search_params.Substancereferenceinformation,
  client: FhirClient,
  handle_response: fn(
    Result(List(resources.Substancereferenceinformation), Err),
  ) ->
    msg,
) -> Effect(msg) {
  substancereferenceinformation_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) ->
        Ok(
          { bundle |> sansio.bundle_to_groupedresources }.substancereferenceinformation,
        )
      Error(error) -> Error(error)
    })
  })
}

pub fn substancesourcematerial_search_bundled(
  _sp: search_params.Substancesourcematerial,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([])
  |> search_any(resources.RtSubstancesourcematerial, client, handle_response)
}

pub fn substancesourcematerial_search(
  sp: search_params.Substancesourcematerial,
  client: FhirClient,
  handle_response: fn(Result(List(resources.Substancesourcematerial), Err)) ->
    msg,
) -> Effect(msg) {
  substancesourcematerial_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) ->
        Ok(
          { bundle |> sansio.bundle_to_groupedresources }.substancesourcematerial,
        )
      Error(error) -> Error(error)
    })
  })
}

pub fn supplydelivery_search_bundled(
  sp: search_params.Supplydelivery,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([
    #("identifier", sp.identifier),
    #("receiver", sp.receiver),
    #("patient", sp.patient),
    #("supplier", sp.supplier),
    #("status", sp.status),
  ])
  |> search_any(resources.RtSupplydelivery, client, handle_response)
}

pub fn supplydelivery_search(
  sp: search_params.Supplydelivery,
  client: FhirClient,
  handle_response: fn(Result(List(resources.Supplydelivery), Err)) -> msg,
) -> Effect(msg) {
  supplydelivery_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) ->
        Ok({ bundle |> sansio.bundle_to_groupedresources }.supplydelivery)
      Error(error) -> Error(error)
    })
  })
}

pub fn supplyrequest_search_bundled(
  sp: search_params.Supplyrequest,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([
    #("date", sp.date),
    #("requester", sp.requester),
    #("identifier", sp.identifier),
    #("patient", sp.patient),
    #("subject", sp.subject),
    #("supplier", sp.supplier),
    #("category", sp.category),
    #("status", sp.status),
  ])
  |> search_any(resources.RtSupplyrequest, client, handle_response)
}

pub fn supplyrequest_search(
  sp: search_params.Supplyrequest,
  client: FhirClient,
  handle_response: fn(Result(List(resources.Supplyrequest), Err)) -> msg,
) -> Effect(msg) {
  supplyrequest_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) ->
        Ok({ bundle |> sansio.bundle_to_groupedresources }.supplyrequest)
      Error(error) -> Error(error)
    })
  })
}

pub fn task_search_bundled(
  sp: search_params.Task,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([
    #("owner", sp.owner),
    #("requestedperformer-reference", sp.requestedperformer_reference),
    #("requester", sp.requester),
    #("business-status", sp.business_status),
    #("identifier", sp.identifier),
    #("period", sp.period),
    #("code", sp.code),
    #("performer", sp.performer),
    #("subject", sp.subject),
    #("focus", sp.focus),
    #("part-of", sp.part_of),
    #("encounter", sp.encounter),
    #("authored-on", sp.authored_on),
    #("priority", sp.priority),
    #("intent", sp.intent),
    #("output", sp.output),
    #("actor", sp.actor),
    #("group-identifier", sp.group_identifier),
    #("based-on", sp.based_on),
    #("patient", sp.patient),
    #("modified", sp.modified),
    #("status", sp.status),
  ])
  |> search_any(resources.RtTask, client, handle_response)
}

pub fn task_search(
  sp: search_params.Task,
  client: FhirClient,
  handle_response: fn(Result(List(resources.Task), Err)) -> msg,
) -> Effect(msg) {
  task_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) -> Ok({ bundle |> sansio.bundle_to_groupedresources }.task)
      Error(error) -> Error(error)
    })
  })
}

pub fn terminologycapabilities_search_bundled(
  sp: search_params.Terminologycapabilities,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([
    #("date", sp.date),
    #("identifier", sp.identifier),
    #("context-type-value", sp.context_type_value),
    #("jurisdiction", sp.jurisdiction),
    #("description", sp.description),
    #("context-type", sp.context_type),
    #("title", sp.title),
    #("version", sp.version),
    #("url", sp.url),
    #("context-quantity", sp.context_quantity),
    #("context", sp.context),
    #("name", sp.name),
    #("publisher", sp.publisher),
    #("context-type-quantity", sp.context_type_quantity),
    #("status", sp.status),
  ])
  |> search_any(resources.RtTerminologycapabilities, client, handle_response)
}

pub fn terminologycapabilities_search(
  sp: search_params.Terminologycapabilities,
  client: FhirClient,
  handle_response: fn(Result(List(resources.Terminologycapabilities), Err)) ->
    msg,
) -> Effect(msg) {
  terminologycapabilities_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) ->
        Ok(
          { bundle |> sansio.bundle_to_groupedresources }.terminologycapabilities,
        )
      Error(error) -> Error(error)
    })
  })
}

pub fn testplan_search_bundled(
  sp: search_params.Testplan,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([
    #("identifier", sp.identifier),
    #("scope", sp.scope),
    #("url", sp.url),
    #("status", sp.status),
  ])
  |> search_any(resources.RtTestplan, client, handle_response)
}

pub fn testplan_search(
  sp: search_params.Testplan,
  client: FhirClient,
  handle_response: fn(Result(List(resources.Testplan), Err)) -> msg,
) -> Effect(msg) {
  testplan_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) -> Ok({ bundle |> sansio.bundle_to_groupedresources }.testplan)
      Error(error) -> Error(error)
    })
  })
}

pub fn testreport_search_bundled(
  sp: search_params.Testreport,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([
    #("result", sp.result),
    #("identifier", sp.identifier),
    #("tester", sp.tester),
    #("testscript", sp.testscript),
    #("issued", sp.issued),
    #("participant", sp.participant),
    #("status", sp.status),
  ])
  |> search_any(resources.RtTestreport, client, handle_response)
}

pub fn testreport_search(
  sp: search_params.Testreport,
  client: FhirClient,
  handle_response: fn(Result(List(resources.Testreport), Err)) -> msg,
) -> Effect(msg) {
  testreport_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) ->
        Ok({ bundle |> sansio.bundle_to_groupedresources }.testreport)
      Error(error) -> Error(error)
    })
  })
}

pub fn testscript_search_bundled(
  sp: search_params.Testscript,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([
    #("date", sp.date),
    #("identifier", sp.identifier),
    #("context-type-value", sp.context_type_value),
    #("jurisdiction", sp.jurisdiction),
    #("description", sp.description),
    #("testscript-capability", sp.testscript_capability),
    #("context-type", sp.context_type),
    #("scope-artifact-phase", sp.scope_artifact_phase),
    #("title", sp.title),
    #("scope-artifact-conformance", sp.scope_artifact_conformance),
    #("version", sp.version),
    #("scope-artifact", sp.scope_artifact),
    #("url", sp.url),
    #("context-quantity", sp.context_quantity),
    #("context", sp.context),
    #("name", sp.name),
    #("publisher", sp.publisher),
    #("context-type-quantity", sp.context_type_quantity),
    #("status", sp.status),
  ])
  |> search_any(resources.RtTestscript, client, handle_response)
}

pub fn testscript_search(
  sp: search_params.Testscript,
  client: FhirClient,
  handle_response: fn(Result(List(resources.Testscript), Err)) -> msg,
) -> Effect(msg) {
  testscript_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) ->
        Ok({ bundle |> sansio.bundle_to_groupedresources }.testscript)
      Error(error) -> Error(error)
    })
  })
}

pub fn transport_search_bundled(
  sp: search_params.Transport,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([
    #("identifier", sp.identifier),
    #("status", sp.status),
  ])
  |> search_any(resources.RtTransport, client, handle_response)
}

pub fn transport_search(
  sp: search_params.Transport,
  client: FhirClient,
  handle_response: fn(Result(List(resources.Transport), Err)) -> msg,
) -> Effect(msg) {
  transport_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) ->
        Ok({ bundle |> sansio.bundle_to_groupedresources }.transport)
      Error(error) -> Error(error)
    })
  })
}

pub fn valueset_search_bundled(
  sp: search_params.Valueset,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([
    #("date", sp.date),
    #("identifier", sp.identifier),
    #("code", sp.code),
    #("context-type-value", sp.context_type_value),
    #("jurisdiction", sp.jurisdiction),
    #("description", sp.description),
    #("derived-from", sp.derived_from),
    #("context-type", sp.context_type),
    #("predecessor", sp.predecessor),
    #("title", sp.title),
    #("version", sp.version),
    #("url", sp.url),
    #("expansion", sp.expansion),
    #("reference", sp.reference),
    #("context-quantity", sp.context_quantity),
    #("effective", sp.effective),
    #("context", sp.context),
    #("name", sp.name),
    #("publisher", sp.publisher),
    #("topic", sp.topic),
    #("context-type-quantity", sp.context_type_quantity),
    #("status", sp.status),
  ])
  |> search_any(resources.RtValueset, client, handle_response)
}

pub fn valueset_search(
  sp: search_params.Valueset,
  client: FhirClient,
  handle_response: fn(Result(List(resources.Valueset), Err)) -> msg,
) -> Effect(msg) {
  valueset_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) -> Ok({ bundle |> sansio.bundle_to_groupedresources }.valueset)
      Error(error) -> Error(error)
    })
  })
}

pub fn verificationresult_search_bundled(
  sp: search_params.Verificationresult,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([
    #("status-date", sp.status_date),
    #("primarysource-who", sp.primarysource_who),
    #("primarysource-date", sp.primarysource_date),
    #("validator-organization", sp.validator_organization),
    #("attestation-method", sp.attestation_method),
    #("attestation-onbehalfof", sp.attestation_onbehalfof),
    #("target", sp.target),
    #("attestation-who", sp.attestation_who),
    #("primarysource-type", sp.primarysource_type),
    #("status", sp.status),
  ])
  |> search_any(resources.RtVerificationresult, client, handle_response)
}

pub fn verificationresult_search(
  sp: search_params.Verificationresult,
  client: FhirClient,
  handle_response: fn(Result(List(resources.Verificationresult), Err)) -> msg,
) -> Effect(msg) {
  verificationresult_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) ->
        Ok({ bundle |> sansio.bundle_to_groupedresources }.verificationresult)
      Error(error) -> Error(error)
    })
  })
}

pub fn visionprescription_search_bundled(
  sp: search_params.Visionprescription,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([
    #("prescriber", sp.prescriber),
    #("identifier", sp.identifier),
    #("patient", sp.patient),
    #("datewritten", sp.datewritten),
    #("encounter", sp.encounter),
    #("status", sp.status),
  ])
  |> search_any(resources.RtVisionprescription, client, handle_response)
}

pub fn visionprescription_search(
  sp: search_params.Visionprescription,
  client: FhirClient,
  handle_response: fn(Result(List(resources.Visionprescription), Err)) -> msg,
) -> Effect(msg) {
  visionprescription_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) ->
        Ok({ bundle |> sansio.bundle_to_groupedresources }.visionprescription)
      Error(error) -> Error(error)
    })
  })
}
