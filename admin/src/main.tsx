import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import App from "./App";
//import "./theme-d-dark.css";
import "./theme-a-editorial.css";

createRoot(document.getElementById("root")!).render(
  <StrictMode>
    <App />
  </StrictMode>,
);
