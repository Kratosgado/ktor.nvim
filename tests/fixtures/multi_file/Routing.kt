package com.example.routing

import io.ktor.server.application.*
import io.ktor.server.auth.*
import io.ktor.server.response.*
import io.ktor.server.routing.*

fun Application.configureRouting() {
    routing {
        get("/health") { call.respond(mapOf("status" to "ok")) }

        route("/api/v1") {
            route("/auth") {
                authRoutes()
            }

            route("/payments") {
                post("/momo/webhook") {
                    call.respond("ok")
                }
            }

            authenticate("jwt") {
                userRoutes()
            }
        }
    }
}
