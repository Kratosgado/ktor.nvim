package com.example.routing

import io.ktor.server.response.*
import io.ktor.server.routing.*

fun Route.authRoutes() {
    post("/login") {
        call.respond("logged in")
    }
    post("/refresh") {
        call.respond("refreshed")
    }
}
