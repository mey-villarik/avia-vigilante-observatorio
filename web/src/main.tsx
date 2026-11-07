import { StrictMode } from 'react';
import { createRoot } from 'react-dom/client';
import './styles/app.css';
import App from './App';
import { Acceso } from './components/Acceso';

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <Acceso>
      <App />
    </Acceso>
  </StrictMode>,
);
