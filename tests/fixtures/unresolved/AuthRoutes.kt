package com.example.unresolved

import io.ktor.server.response.*
import io.ktor.server.routing.*

fun Route.sessionAuthRoutes() {
    get("/session") {
        call.respond("session")
    }
}
