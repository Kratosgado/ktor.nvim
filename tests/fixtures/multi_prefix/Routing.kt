package com.example.routing

import io.ktor.server.application.*
import io.ktor.server.auth.*
import io.ktor.server.response.*
import io.ktor.server.routing.*

fun Application.configureRouting() {
    routing {
        route("/api/v1") {
            route("/academic-years") {
                get("/") {
                    call.respond(mapOf("years" to emptyList<String>()))
                }
            }
        }

        route("/api/v1") {
            route("/terms") {
                get("/") {
                    call.respond(mapOf("terms" to emptyList<String>()))
                }
            }
        }

        route("/api/v1") {
            route("/setup") {
                authenticate("jwt") {
                    post("/academic-year") {
                        call.respond("ok")
                    }
                }
            }
        }

        post("/api/v1/test/reset") {
            call.respond("reset")
        }
    }
}
