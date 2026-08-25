package com.example.routes

import io.ktor.server.application.*
import io.ktor.server.auth.*
import io.ktor.server.response.*
import io.ktor.server.routing.*

fun Application.configureRouting() {
    routing {
        route("/api/v1") {
            route("/schools/{schoolId}") {
                authenticate("admin-jwt") {
                    get("/students/{id}") {
                        call.respond("one student")
                    }
                    put("/students/{id}") {
                        call.respond("updated student")
                    }
                    delete("/students/{id}") {
                        call.respond("deleted student")
                    }
                }
                get("/students") {
                    call.respond("all students")
                }
                post("/students") {
                    call.respond("created student")
                }
            }
            route("/auth") {
                post("/login") {
                    call.respond("logged in")
                }
            }
        }
        route("/health") {
            get {
                call.respond("ok")
            }
        }
    }
}

