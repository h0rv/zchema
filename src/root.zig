//! zchema: a thin typed-contract layer for Zig's standard HTTP server.
//!
//! zchema adds JSON request parsing, response serialization, JSON Schema
//! validation, and OpenAPI 3.1 generation on top of `std.http.Server`, without
//! taking ownership of the accept loop, socket lifecycle, threading model, or
//! non-JSON HTTP behavior. `std.http.Server.Request` stays available everywhere.
//!
//! The API is layered (a documentation device, not a code structure):
//!   - Helper functions for existing handlers: `body`, `jsonBody`, `respondJson`.
//!   - Route registration and signature markers: `Api`, `get`/`post`/..., `Body`,
//!     `Created`, `Status`.
//!   - Explicit request/response contracts: `Request`, `Response`, `case`.
//!   - OpenAPI 3.1 generation from registered routes: `openApiJson`, `writeOpenApi`.

const std = @import("std");

const helpers = @import("helpers.zig");
const markers = @import("markers.zig");
const routes = @import("routes.zig");
const contract = @import("contract.zig");
const openapi = @import("openapi.zig");
const dispatch = @import("dispatch.zig");
const errors = @import("errors.zig");
const validation = @import("validation.zig");
const docs = @import("docs.zig");
const app = @import("app.zig");
const params = @import("params.zig");

// --- Helper functions -------------------------------------------------------

pub const BodyOptions = helpers.BodyOptions;
pub const ResponseOptions = helpers.ResponseOptions;
pub const body = helpers.body;
pub const jsonBody = helpers.jsonBody;
pub const jsonBodyWithErrors = helpers.jsonBodyWithErrors;
pub const respondJson = helpers.respondJson;
pub const respondJsonRaw = helpers.respondJsonRaw;
pub const respondError = helpers.respondError;
pub const respondErrorBody = helpers.respondErrorBody;
pub const pathEql = helpers.pathEql;
pub const pathParam = helpers.pathParam;
pub const header = helpers.header;
pub const headerWith = helpers.headerWith;
pub const HeaderCase = helpers.HeaderCase;
pub const targetPath = helpers.targetPath;
pub const isJsonContentType = helpers.isJsonContentType;

// --- Signature markers ------------------------------------------------------

pub const Body = markers.Body;
pub const Path = markers.Path;
pub const Query = markers.Query;
pub const Header = markers.Header;
pub const Created = markers.Created;
pub const Status = markers.Status;

// --- Route registration -----------------------------------------------------

pub const Route = routes.Route;
pub const Api = routes.Api;
pub const get = routes.get;
pub const post = routes.post;
pub const put = routes.put;
pub const patch = routes.patch;
pub const delete = routes.delete;
pub const raw = routes.raw;
pub const op = routes.op;
pub const endpoint = routes.endpoint;
pub const Spec = routes.Spec;
pub const operation = routes.operation;
pub const Operation = routes.Operation;
pub const OperationParam = routes.OperationParam;
pub const OperationResponse = routes.OperationResponse;
pub const ParamIn = routes.ParamIn;

// --- Explicit contracts -----------------------------------------------------

pub const Request = contract.Request;
pub const Response = contract.Response;
pub const case = contract.case;
pub const emptyCase = contract.emptyCase;
pub const ResponseCase = contract.ResponseCase;

// --- OpenAPI ----------------------------------------------------------------

pub const OpenApiOptions = openapi.OpenApiOptions;
pub const openApiJson = openapi.openApiJson;
pub const writeOpenApi = openapi.writeOpenApi;

// --- Docs UI ----------------------------------------------------------------

pub const DocsUi = docs.DocsUi;
pub const DocsOptions = docs.DocsOptions;
pub const DocsAssets = docs.DocsAssets;
pub const ScalarConfig = docs.ScalarConfig;
pub const docsHtml = docs.docsHtml;
pub const writeDocsHtml = docs.writeDocsHtml;
pub const respondDocs = docs.respondDocs;

// --- Dispatch and App -------------------------------------------------------

pub const DispatchOptions = dispatch.DispatchOptions;
pub const handle = dispatch.handle;
pub const App = app.App;
pub const ServeConfig = app.ServeConfig;
pub const DocsServe = app.DocsServe;

// --- Errors and schema access ----------------------------------------------

pub const Error = errors.Error;
pub const ErrorBody = errors.ErrorBody;
pub const FieldError = errors.FieldError;
pub const errorBody = errors.errorBody;
pub const errorBodyFor = errors.errorBodyFor;
pub const errorStatus = errors.statusForError;
pub const errorDetail = errors.detailForError;
pub const schemaText = validation.schemaText;
pub const schemaName = validation.schemaName;

// --- Server-agnostic validation primitives ----------------------------------
// These operate on raw bytes / parsed values, not on `std.http`, so they can be
// used with any server (for example http.zig) to validate requests and
// responses without zchema's dispatcher.

pub const parseAndValidate = validation.parseAndValidate;
pub const validateValue = validation.validateValue;
pub const serializeAndValidate = validation.serializeAndValidate;

test {
    _ = helpers;
    _ = markers;
    _ = routes;
    _ = contract;
    _ = openapi;
    _ = dispatch;
    _ = errors;
    _ = validation;
    _ = docs;
    _ = app;
    _ = params;
}
